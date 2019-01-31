//
//  Interpret.swift
//  Bits
//
//  Created by Chris Eidhof on 24.08.18.
//

import Foundation
import PostgreSQL
import NIOHTTP1

extension Swift.Collection where Element == Episode {
    func withProgress<I: Interp>(for id: UUID?, _ cont: @escaping ([EpisodeWithProgress]) -> I) -> I {
        guard let userId = id else { return cont(map { EpisodeWithProgress(episode: $0, progress: nil )}) }
        
        return I.query(Row<PlayProgressData>.sortedDesc(for: userId).map { results in
        	let progresses = results.map { $0.data }
            return self.map { episode in
            // todo this is (n*m), we should use the fact that `progresses` is sorted!
            EpisodeWithProgress(episode: episode, progress: progresses.first { $0.episodeNumber == episode.number }?.progress)
            }
        }, cont)
    }
}

typealias Interp = SwiftTalkInterpreter & HTML & HasSession & HasDatabase

extension Route {
    func interpret<I: Interp>() throws -> I {
        switch self {
        case .error:
            return .write(errorView("Not found"), status: .notFound)
        case .collections:
            return I.withSession { session in
                I.write(index(Collection.all.filter { !$0.episodes(for: session?.user.data).isEmpty }))
            }
        case .subscription(let s):
            return try s.interpret()
        case .account(let action):
            return try action.interpret()
        case .gift(let g):
            return try g.interpret()
        case let .episode(id, action):
            return try action.interpret(id: id)
        case .subscribe: // this isn't in .subscribe because it doesn't require a session.
            guard let monthly = Plan.monthly, let yearly = Plan.yearly else {
                throw ServerError(privateMessage: "Can't find monthly or yearly plan: \([Plan.all])", publicMessage: "Something went wrong, please try again later")
            }
            return I.write(renderSubscribe(monthly: monthly, yearly: yearly))
        case .subscribeTeam:
            guard let monthly = Plan.monthly, let yearly = Plan.yearly else {
                throw ServerError(privateMessage: "Can't find monthly or yearly plan: \([Plan.all])", publicMessage: "Something went wrong, please try again later")
            }
            return I.write(renderSubscribeTeam(monthly: monthly, yearly: yearly))
        case .teamMemberSignup(let token):
            return I.query(Row<UserData>.select(teamToken: token)) { row in
                guard let teamManager = row else {
                    throw ServerError(privateMessage: "signup token doesn't exist: \(token)", publicMessage: "This signup link is invalid. Please get in touch with your team manager for a new one.")
                }
                return I.withSession { session in
                    if let s = session {
                        if s.user.id == teamManager.id && s.selfPremiumAccess {
                            return I.write(teamMemberSubscribeForAlreadyPartOfThisTeam())
                        } else if s.selfPremiumAccess {
                            return I.write(teamMemberSubscribeForSelfSubscribed(signupToken: token))
                        } else if s.isTeamMemberOf(teamManager) {
                            return I.write(teamMemberSubscribeForAlreadyPartOfThisTeam())
                        } else {
                            return I.write(teamMemberSubscribeForSignedIn(signupToken: token))
                        }
                    } else {
                        return I.write(teamMemberSubscribe(signupToken: token))
                    }
                }
            }
        case .collection(let name):
            guard let coll = Collection.all.first(where: { $0.id == name }) else {
                return .write(errorView("No such collection"), status: .notFound)
            }
            return I.withSession { session in
                return coll.episodes(for: session?.user.data).withProgress(for: session?.user.id) {
                    I.write(coll.show(episodes: $0))
                }
            }
        case .login(let cont):
            var path = "https://github.com/login/oauth/authorize?scope=user:email&client_id=\(github.clientId)"
            if let c = cont {
                let encoded = env.baseURL.absoluteString + Route.githubCallback(code: nil, origin: c.path).path
                path.append("&redirect_uri=" + encoded.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)!)
            }
            return I.redirect(path: path, headers: [:])
        case .githubCallback(let optionalCode, let origin):
            guard let code = optionalCode else {
                throw ServerError(privateMessage: "No auth code", publicMessage: "Something went wrong, please try again.")
            }
            let loadToken = github.getAccessToken(code).promise.map({ $0?.access_token })
            return I.onCompleteOrCatch(promise: loadToken, do: { token in
                let t = try token ?! ServerError(privateMessage: "No github access token", publicMessage: "Couldn't access your Github profile.")
                let loadProfile = Github(accessToken: t).profile.promise
                return I.onSuccess(promise: loadProfile, message: "Couldn't access your Github profile", do: { profile in
                    let uid: UUID
                    return I.query(Row<UserData>.select(githubId: profile.id)) {
                        func createSession(uid: UUID) -> I {
                            return I.query(SessionData(userId: uid).insert) { sid in
                                let destination: String
                                if let o = origin?.removingPercentEncoding, o.hasPrefix("/") {
                                    destination = o
                                } else {
                                    destination = "/"
                                }
                                return I.redirect(path: destination, headers: ["Set-Cookie": "sessionid=\"\(sid.uuidString)\"; HttpOnly; Path=/"]) // TODO secure
                            }
                        }
                        if let user = $0 {
                            return createSession(uid: user.id)
                        } else {
                            let userData = UserData(email: profile.email ?? "", githubUID: profile.id, githubLogin: profile.login, githubToken: t, avatarURL: profile.avatar_url, name: profile.name ?? "")
                            return I.query(userData.insert, createSession)
                        }
                        
                        
                    }
                })
            })

        case .episodes:
            return I.withSession { session in
                let scoped = Episode.all.scoped(for: session?.user.data)
                return scoped.withProgress(for: session?.user.id,  { I.write(index($0)) })
            }
        case .home:
            return I.withSession { session in
                let scoped = Episode.all.scoped(for: session?.user.data)
                return scoped.withProgress(for: session?.user.id) { .write(renderHome(episodes: $0)) }
            }
        case .sitemap:
            return .write(Route.siteMap)
        case .promoCode(let str):
            return I.onSuccess(promise: recurly.coupon(code: str).promise, message: "Can't find that coupon.", do: { coupon in
                guard coupon.state == "redeemable" else {
                    throw ServerError(privateMessage: "not redeemable: \(str)", publicMessage: "This coupon is not redeemable anymore.")
                }
                guard let m = Plan.monthly, let y = Plan.yearly else {
                    throw ServerError(privateMessage: "Plans not loaded", publicMessage: "A small hiccup. Please try again in a little while.")
                }
                return I.write(renderSubscribe(monthly: m, yearly: y, coupon: coupon))
            })
       
        case let .staticFile(path: p):
            let name = p.map { $0.removingPercentEncoding ?? "" }.joined(separator: "/")
            if let n = assets.hashToFile[name] {
                return I.writeFile(path: n, maxAge: 31536000)
            } else {
            	return .writeFile(path: name)
            }
        case .recurlyWebhook:
            return I.withPostData { data in
                guard let webhook: Webhook = try? decodeXML(from: data) else { return I.write("", status: .ok) }
                let id = webhook.account.account_code
                recurly.subscriptionStatus(for: webhook.account.account_code).run { status in
                    let c = lazyConnection()
                    guard let s = status else {
                        return log(error: "Received Recurly webhook for account id \(id), but couldn't load this account from Recurly")
                    }
                    guard let r = try? c.get().execute(Row<UserData>.select(id)), var row = r else {
                        return log(error: "Received Recurly webhook for account \(id), but didn't find user in database")
                    }
                    row.data.subscriber = s.subscriber
                    row.data.downloadCredits = Int(s.downloadCredits)
                    row.data.canceled = s.canceled
                    tryOrLog("Failed to update user \(id) in response to Recurly webhook") { try c.get().execute(row.update()) }
                }
                
                return catchAndDisplayError {
                    if let s = webhook.subscription, s.plan.plan_code.hasPrefix("gift") {
                        return I.query(Row<GiftData>.select(subscriptionId: s.uuid)) {
                            if var gift = flatten($0) {
                                log(info: "gift update \(s) \(gift)")
                                let ok = { I.write("", status: .ok) }
                                if s.state == "future", let a = s.activated_at {
                                    if gift.data.sendAt != a {
                                        gift.data.sendAt = a
                                        return I.query(gift.update(), ok)
                                    }
                                } else if s.state == "active" {
                                    if !gift.data.activated {
                                        let plan = Plan.gifts.first { $0.plan_code == s.plan.plan_code }
                                        let duration = plan?.prettyDuration ?? "unknown"
                                        let email = sendgrid.send(to: gift.data.gifteeEmail, name: gift.data.gifteeName, subject: "We have a gift for you...", text: gift.gifteeEmailText(duration: duration))
                                        log(info: "Sending gift email to \(gift.data.gifteeEmail)")
                                        globals.urlSession.load(email) { result in
                                            if result == nil {
                                                log(error: "Can't send email for gift \(gift)")
                                            }
                                        }
                                        gift.data.activated = true
                                        return I.query(gift.update(), ok)
                                    }
                                }
                                return ok()
                            } else {
                                log(error: "Got a recurly webhook but can't find gift \(s)")
                                return I.write("", status: .internalServerError)
                            }
                        }
                    }
                    return I.write("")
                }
            }
        case .githubWebhook:
            // This could be done more fine grained, but this works just fine for now
            refreshStaticData()
            return I.write("")
        case .rssFeed:
            return I.write(rss: Episode.all.released.rssView)
        case .episodesJSON:
            return I.write(json: episodesJSONView())
        case .collectionsJSON:
            return I.write(json: collectionsJSONView())
        }
    }
}

let sharedCSRF = CSRFToken(UUID(uuidString: "F5F6C2AE-85CB-4989-B0BF-F471CC92E3FF")!)
