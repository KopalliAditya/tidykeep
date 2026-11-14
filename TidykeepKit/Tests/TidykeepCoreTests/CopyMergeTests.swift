import Testing
import TidykeepCore

/// Which copies a merge can remove, so the kept copy ends up in every album they were in.
@Suite struct CopyMergeTests {
    /// "b" is in a synced album the keeper isn't in and can't join, so "b" stays and the album
    /// keeps the photo. "c" goes, and the keeper joins its album.
    @Test func aCopyInAnAlbumTheKeeperCantJoinStays() {
        let albums = [
            PhotoAlbum(id: "synced", title: "Synced", assetIDs: ["b"], canAddPhotos: false),
            PhotoAlbum(id: "trip", title: "Trip", assetIDs: ["c"]),
        ]
        let merge = CopyMerge(keeperID: "a", removeIDs: ["b", "c"]).sparingAlbums(albums)
        #expect(merge.keeperID == "a")
        #expect(merge.removeIDs == ["c"])
        #expect(merge.albumsToJoin(albums).map(\.id) == ["trip"])
    }

    /// The keeper is already in the album it couldn't join, so nothing is lost and the copy can go.
    @Test func aCopyCanGoWhenTheKeeperIsAlreadyInTheAlbum() {
        let albums = [PhotoAlbum(id: "synced", title: "Synced", assetIDs: ["a", "b"], canAddPhotos: false)]
        let merge = CopyMerge(keeperID: "a", removeIDs: ["b"]).sparingAlbums(albums)
        #expect(merge.removeIDs == ["b"])
        #expect(merge.albumsToJoin(albums).isEmpty)
    }

    /// Only albums a removed copy is in are joined, never one only the keeper or a kept copy is in.
    @Test func theKeeperJoinsOnlyTheAlbumsOfRemovedCopies() {
        let albums = [
            PhotoAlbum(id: "home", title: "Home", assetIDs: ["a"]),
            PhotoAlbum(id: "kept", title: "Kept", assetIDs: ["d"]),
            PhotoAlbum(id: "trip", title: "Trip", assetIDs: ["b", "c"]),
            PhotoAlbum(id: "work", title: "Work", assetIDs: ["c"]),
        ]
        let merge = CopyMerge(keeperID: "a", removeIDs: ["b", "c"]).sparingAlbums(albums)
        #expect(merge.removeIDs == ["b", "c"])
        #expect(merge.albumsToJoin(albums).map(\.id) == ["trip", "work"])
    }
}
