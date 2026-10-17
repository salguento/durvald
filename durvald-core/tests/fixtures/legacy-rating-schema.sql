-- Pre-half-star catalog, deliberately using the old 0...5 rating column.
PRAGMA foreign_keys=ON;
CREATE TABLE artists(artist_id INTEGER PRIMARY KEY, name TEXT);
CREATE TABLE releases(
    release_id INTEGER PRIMARY KEY, title TEXT, artist_id INTEGER NOT NULL,
    artist_name TEXT NOT NULL, release_date DATETIME, total_tracks INTEGER DEFAULT 1,
    total_discs INTEGER DEFAULT 1, duration INTEGER, artwork TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    is_favorite BOOL DEFAULT FALSE, is_hidden BOOL DEFAULT FALSE, suggest_less BOOL DEFAULT FALSE,
    rating INTEGER CHECK(rating IS NULL OR rating BETWEEN 0 AND 5),
    FOREIGN KEY(artist_id) REFERENCES artists(artist_id) ON DELETE CASCADE
);
CREATE TABLE songs(
    song_id INTEGER PRIMARY KEY, title TEXT NOT NULL, artwork TEXT,
    artist_id INTEGER NOT NULL, artist_name TEXT NOT NULL, release_id INTEGER NOT NULL,
    release_title TEXT NOT NULL, track_number INTEGER NOT NULL, disc_number INTEGER NOT NULL DEFAULT 1,
    duration INTEGER NOT NULL, bitrate INTEGER, sample_rate INTEGER, bit_depth INTEGER,
    play_count INTEGER DEFAULT 0, last_played DATETIME,
    rating INTEGER CHECK(rating IS NULL OR rating BETWEEN 0 AND 5), lyrics TEXT,
    is_favorite BOOL DEFAULT FALSE, is_hidden BOOL DEFAULT FALSE, suggest_less BOOL DEFAULT FALSE,
    file_path TEXT NOT NULL, created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP, file_mtime INTEGER, metadata_version INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE playlists(
    id INTEGER PRIMARY KEY, name TEXT, cover BLOB, description TEXT,
    is_favorite BOOL DEFAULT FALSE, suggest_less BOOL DEFAULT FALSE,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP, updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE playlist_songs(
    playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
    song_id INTEGER NOT NULL REFERENCES songs(song_id) ON DELETE CASCADE,
    position INTEGER NOT NULL, added_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY(playlist_id,song_id,position)
);
INSERT INTO artists VALUES(1,'Legacy artist');
INSERT INTO releases(release_id,title,artist_id,artist_name,duration,rating)
    VALUES(1,'Legacy album',1,'Legacy artist',180,4);
INSERT INTO songs(song_id,title,artist_id,artist_name,release_id,release_title,
    track_number,duration,file_path,rating,is_favorite,play_count) VALUES
    (1,'Unrated',1,'Legacy artist',1,'Legacy album',1,180,'/legacy/1.flac',NULL,0,0),
    (2,'Rated zero',1,'Legacy artist',1,'Legacy album',2,180,'/legacy/2.flac',0,0,0),
    (3,'Three stars',1,'Legacy artist',1,'Legacy album',3,180,'/legacy/3.flac',3,1,19),
    (4,'Five stars',1,'Legacy artist',1,'Legacy album',4,180,'/legacy/4.flac',5,0,0);
INSERT INTO playlists(id,name,description) VALUES(7,'Existing playlist','Keep links and order');
INSERT INTO playlist_songs(playlist_id,song_id,position) VALUES(7,3,0),(7,1,1);
