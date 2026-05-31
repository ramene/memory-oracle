import ExpoModulesCore

public class SeAgeModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SeAge")

    Function("isAvailable") { () -> Bool in
      SeAgeService.isAvailable()
    }

    AsyncFunction("getOrCreateIdentity") { (tag: String, promise: Promise) in
      do {
        let recipient = try SeAgeService.getOrCreateIdentity(tag: tag)
        promise.resolve(recipient)
      } catch {
        promise.reject(SeAgeJsError.from(error))
      }
    }

    AsyncFunction("getRecipient") { (tag: String, promise: Promise) in
      do {
        let recipient = try SeAgeService.getRecipient(tag: tag)
        promise.resolve(recipient)
      } catch {
        promise.reject(SeAgeJsError.from(error))
      }
    }

    AsyncFunction("performKeyAgreement") {
      (tag: String, peerRecipient: String, reason: String, promise: Promise) in
      do {
        let shared = try SeAgeService.performKeyAgreement(
          tag: tag, peerRecipient: peerRecipient, reason: reason)
        promise.resolve(shared)
      } catch {
        promise.reject(SeAgeJsError.from(error))
      }
    }

    AsyncFunction("deleteIdentity") { (tag: String, promise: Promise) in
      do {
        let ok = try SeAgeService.deleteIdentity(tag: tag)
        promise.resolve(ok)
      } catch {
        promise.reject(SeAgeJsError.from(error))
      }
    }
  }
}

private struct SeAgeJsError {
  static func from(_ error: Error) -> Exception {
    if let e = error as? SeAgeError {
      return Exception(name: e.code, description: e.localizedDescription)
    }
    return Exception(name: "SeAgeUnknown", description: error.localizedDescription)
  }
}
