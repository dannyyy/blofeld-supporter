import Foundation

/// One error message from `GET /api/endpoints/<endpoint>/errors/?status=unresolved`.
/// We only decode the field we need to classify "new" vs "retried".
struct ErrorMessage: Decodable {
    let numberOfProcessingAttempts: Int

    enum CodingKeys: String, CodingKey {
        case numberOfProcessingAttempts = "number_of_processing_attempts"
    }
}

/// One entry from `GET /api/recoverability/groups/Endpoint%20Name`.
/// `id` becomes the ServicePulse `<GROUP-ID>`; `title` is the endpoint name.
struct RecoverabilityGroup: Decodable {
    let id: String
    let title: String
}
