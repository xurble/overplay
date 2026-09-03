import Foundation

/// Decides whether an automatic sync cycle can skip refetching a playlist's
/// tracks.
///
/// Paging a playlist's tracks is the most expensive Apple Music call
/// Overplay makes, and a 30-minute cycle repeats it for every linked
/// playlist whether or not anything changed. Apple Music reports when a
/// library playlist was last modified, so an unchanged playlist needs no
/// track fetch at all.
///
/// Deliberately conservative: anything unknown means fetch. A needless
/// fetch only costs a request, whereas a wrong skip would leave Overplay
/// blind to real playlist changes.
enum PlaylistRemoteChangePolicy {
    static func isUnchanged(
        remoteLastModifiedAt: Date?,
        storedLastModifiedAt: Date?,
        hasSyncedSuccessfully: Bool
    ) -> Bool {
        // Without a successful previous sync there is no local track data to
        // trust, whatever the timestamps say.
        guard hasSyncedSuccessfully else { return false }
        // Apple Music does not report a modification date for every library
        // playlist, and a missing stored date means Overplay has never
        // recorded a fingerprint for this playlist.
        guard let remoteLastModifiedAt, let storedLastModifiedAt else { return false }
        return remoteLastModifiedAt == storedLastModifiedAt
    }
}
