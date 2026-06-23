import Foundation
import SwiftData

enum SpotifyCredentialsRepository {
    static func credentials(in context: ModelContext) throws -> SpotifyCredentialsRecord? {
        var descriptor = FetchDescriptor<SpotifyCredentialsRecord>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        descriptor.includePendingChanges = true
        return try context.fetch(descriptor).first
    }

    @discardableResult
    static func upsert(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date,
        scope: String,
        spotifyUserID: String,
        displayName: String,
        in context: ModelContext
    ) throws -> SpotifyCredentialsRecord {
        let record = try credentials(in: context) ?? SpotifyCredentialsRecord()
        if record.modelContext == nil {
            context.insert(record)
        }

        record.accessToken = accessToken
        if let refreshToken, !refreshToken.isEmpty {
            record.refreshToken = refreshToken
        }
        record.expiresAt = expiresAt
        record.scope = scope
        record.spotifyUserID = spotifyUserID
        record.displayName = displayName
        record.updatedAt = .now
        return record
    }

    static func delete(in context: ModelContext) throws {
        let records = try context.fetch(FetchDescriptor<SpotifyCredentialsRecord>())
        for record in records {
            context.delete(record)
        }
    }
}
