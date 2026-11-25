import Foundation

/// Clipboard history as rows.
///
/// The same operations the JSON store offered, each now touching only what it
/// changes: adding a copy writes one row rather than the whole history.
struct ClipboardHistoryDatabase {
    let database: ShortyDatabase

    /// Writes an item, replacing whatever was there under the same id.
    ///
    /// Rows for the parts of an item that are lists are deleted and written
    /// again rather than reconciled: there are never more than a handful, and
    /// matching them up would cost more than rewriting them.
    func write(_ item: ClipboardItem) throws {
        try database.locked {
            try database.sqlite.transaction {
                try database.sqlite.run(
                    """
                    INSERT INTO items (
                        id, plain_text, rtf, rtfd, created_at, updated_at,
                        source_bundle, source_name,
                        image_file, image_type, image_bytes, image_width, image_height
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        plain_text = excluded.plain_text,
                        rtf = excluded.rtf,
                        rtfd = excluded.rtfd,
                        created_at = excluded.created_at,
                        updated_at = excluded.updated_at,
                        source_bundle = excluded.source_bundle,
                        source_name = excluded.source_name,
                        image_file = excluded.image_file,
                        image_type = excluded.image_type,
                        image_bytes = excluded.image_bytes,
                        image_width = excluded.image_width,
                        image_height = excluded.image_height
                    """,
                    [
                        .text(item.id),
                        .text(item.plainText),
                        item.rtfData.map(SQLiteValue.blob) ?? .null,
                        item.rtfdData.map(SQLiteValue.blob) ?? .null,
                        .real(item.createdAt.timeIntervalSince1970),
                        .real(item.updatedAt.timeIntervalSince1970),
                        item.source?.bundleID.map(SQLiteValue.text) ?? .null,
                        item.source?.name.map(SQLiteValue.text) ?? .null,
                        item.image.map { SQLiteValue.text($0.fileName) } ?? .null,
                        item.image.map { SQLiteValue.text($0.type) } ?? .null,
                        item.image.map { SQLiteValue.integer(Int64($0.byteSize)) } ?? .null,
                        item.image.map { SQLiteValue.integer(Int64($0.pixelWidth)) } ?? .null,
                        item.image.map { SQLiteValue.integer(Int64($0.pixelHeight)) } ?? .null,
                    ]
                )

                try database.sqlite.run("DELETE FROM representations WHERE item_id = ?", [.text(item.id)])
                try database.sqlite.run("DELETE FROM files WHERE item_id = ?", [.text(item.id)])

                for (position, representation) in item.additionalRepresentations.enumerated() {
                    try database.sqlite.run(
                        "INSERT INTO representations (item_id, position, type, data) VALUES (?, ?, ?, ?)",
                        [
                            .text(item.id),
                            .integer(Int64(position)),
                            .text(representation.type),
                            .blob(representation.data),
                        ]
                    )
                }

                for (position, file) in item.files.enumerated() {
                    try database.sqlite.run(
                        "INSERT INTO files (item_id, position, path) VALUES (?, ?, ?)",
                        [.text(item.id), .integer(Int64(position)), .text(file.path)]
                    )
                }
            }
        }
    }

    /// What a previous copy of the same thing recorded, by primary key.
    ///
    /// Only the two fields that survive a re-copy, rather than the whole
    /// item: this runs on every copy, and rebuilding an entry here means
    /// two more queries for its representations and files.
    func existing(id: String) throws -> (createdAt: Date, source: ClipboardSource?)? {
        try database.locked {
            let rows = try database.sqlite.query(
                "SELECT created_at, source_bundle, source_name FROM items WHERE id = ?",
                [.text(id)]
            )

            guard let row = rows.first else {
                return nil
            }

            let source: ClipboardSource? = (row[1].string == nil && row[2].string == nil)
                ? nil
                : ClipboardSource(bundleID: row[1].string, name: row[2].string)

            return (Date(timeIntervalSince1970: row[0].double ?? 0), source)
        }
    }

    @discardableResult
    func remove(id: String) throws -> Bool {
        try database.locked {
            try database.sqlite.run("DELETE FROM items WHERE id = ?", [.text(id)]) > 0
        }
    }

    /// The newest entries, which is the order the picker shows.
    func recentItems(limit: Int) throws -> [ClipboardItem] {
        try database.locked {
            let rows = try database.sqlite.query(
                """
                SELECT id, plain_text, rtf, rtfd, created_at, updated_at,
                       source_bundle, source_name,
                       image_file, image_type, image_bytes, image_width, image_height
                FROM items
                ORDER BY updated_at DESC
                LIMIT ?
                """,
                [.integer(Int64(limit))]
            )

            return try rows.compactMap(item(from:))
        }
    }

    func count() throws -> Int {
        try database.locked {
            Int(try database.sqlite.query("SELECT COUNT(*) FROM items").first?.first?.int ?? 0)
        }
    }

    /// Drops everything past the newest `limit`.
    ///
    /// By date rather than by `id NOT IN (…)`: the subquery form re-sorted
    /// the whole table on every copy, which put the cost back where moving
    /// off JSON was meant to take it from. This walks the recency index to
    /// the cut-off row and deletes below it.
    @discardableResult
    func trim(to limit: Int) throws -> Bool {
        try database.locked {
            let cutoff = try database.sqlite.query(
                "SELECT updated_at FROM items ORDER BY updated_at DESC LIMIT 1 OFFSET ?",
                [.integer(Int64(limit))]
            )

            // Nothing past the limit, which is the usual answer.
            guard let oldest = cutoff.first?.first?.double else {
                return false
            }

            let removed = try database.sqlite.run(
                "DELETE FROM items WHERE updated_at <= ?",
                [.real(oldest)]
            )

            return removed > 0
        }
    }

    /// Every image still spoken for, for the orphan sweep.
    func referencedAssets() throws -> [ClipboardAsset] {
        try database.locked {
            let rows = try database.sqlite.query(
                """
                SELECT image_file, image_type, image_bytes, image_width, image_height
                FROM items WHERE image_file IS NOT NULL
                """
            )

            return rows.compactMap { row in
                guard let fileName = row[0].string, let type = row[1].string else {
                    return nil
                }

                return ClipboardAsset(
                    fileName: fileName,
                    type: type,
                    byteSize: Int(row[2].int ?? 0),
                    pixelWidth: Int(row[3].int ?? 0),
                    pixelHeight: Int(row[4].int ?? 0)
                )
            }
        }
    }

    private func item(from row: [SQLiteValue]) throws -> ClipboardItem? {
        guard let id = row[0].string, let plainText = row[1].string else {
            return nil
        }

        let representations = try database.sqlite.query(
            "SELECT type, data FROM representations WHERE item_id = ? ORDER BY position",
            [.text(id)]
        ).compactMap { representation -> ClipboardRepresentation? in
            guard let type = representation[0].string, let data = representation[1].data else {
                return nil
            }

            return ClipboardRepresentation(type: type, data: data)
        }

        let files = try database.sqlite.query(
            "SELECT path FROM files WHERE item_id = ? ORDER BY position",
            [.text(id)]
        ).compactMap { $0[0].string.map(ClipboardFileReference.init(path:)) }

        let source: ClipboardSource? = (row[6].string == nil && row[7].string == nil)
            ? nil
            : ClipboardSource(bundleID: row[6].string, name: row[7].string)

        let image: ClipboardAsset? = row[8].string.map { fileName in
            ClipboardAsset(
                fileName: fileName,
                type: row[9].string ?? "",
                byteSize: Int(row[10].int ?? 0),
                pixelWidth: Int(row[11].int ?? 0),
                pixelHeight: Int(row[12].int ?? 0)
            )
        }

        // The id is the hash of exactly these fields, so rebuilding the item
        // rebuilds the same id; the column is what rows are keyed and
        // deduplicated by.
        return ClipboardItem(
            plainText: plainText,
            rtfData: row[2].data,
            rtfdData: row[3].data,
            additionalRepresentations: representations,
            createdAt: Date(timeIntervalSince1970: row[4].double ?? 0),
            updatedAt: Date(timeIntervalSince1970: row[5].double ?? 0),
            source: source,
            image: image,
            files: files
        )
    }
}
