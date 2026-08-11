import Photos

/// Saves recorded video files to the user's Photos library.
enum PhotoLibrarySaver {

    /// Saves both portrait and landscape videos to the Photos library.
    ///
    /// The two files are saved in separate performChanges calls so that
    /// portrait always receives an earlier creation timestamp than landscape.
    /// Saving both in the same block gives them identical timestamps, and
    /// Photos has no stable tiebreaker — the display order then flips between
    /// recordings.  Sequential saves guarantee portrait always appears first.
    static func saveBothVideos(
        portraitURL: URL,
        landscapeURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugSimulateSaveFailure") {
            completion(.failure(SaveError.simulatedFailure))
            return
        }
        #endif

        // Step 1: save portrait
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: portraitURL)
        } completionHandler: { success, error in
            if !success {
                completion(.failure(error ?? SaveError.unknownError))
                return
            }
            // Step 2: save landscape after portrait has been committed
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: landscapeURL)
            } completionHandler: { success2, error2 in
                if success2 {
                    completion(.success(()))
                } else {
                    completion(.failure(error2 ?? SaveError.unknownError))
                }
            }
        }
    }

    /// Saves a single video to the Photos library.
    static func saveVideo(
        url: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugSimulateSaveFailure") {
            completion(.failure(SaveError.simulatedFailure))
            return
        }
        #endif

        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        } completionHandler: { success, error in
            if success {
                completion(.success(()))
            } else if let error = error {
                completion(.failure(error))
            } else {
                completion(.failure(SaveError.unknownError))
            }
        }
    }

    enum SaveError: LocalizedError {
        case unknownError
        case simulatedFailure

        var errorDescription: String? {
            switch self {
            case .unknownError:     return "An unknown error occurred while saving to Photos."
            case .simulatedFailure: return "Simulated save failure (debug only)."
            }
        }
    }
}
