BEGIN TRANSACTION;
CREATE TABLE IF NOT EXISTS size_calculate (id TEXT PRIMARY KEY ,total_size TEXT, is_process TEXT, pid TEXT, time TEXT, errcode TEXT);
CREATE TABLE IF NOT EXISTS snap_replica_conf (replica_id TEXT PRIMARY KEY ,plan_status TEXT, direction TEXT, src_path TEXT, dst_path TEXT, dstnodeid TEXT, token TEXT, additional TEXT);
CREATE TABLE IF NOT EXISTS db_ver (value INTEGER);
INSERT INTO db_ver (value) VALUES (1);
COMMIT TRANSACTION;
