CREATE TABLE ftpxfer (
	time int4 NOT NULL,
	ip inet,
	username VARCHAR(256),
	cmd VARCHAR(16),
	filesize int8,
	filename text,
	isdir boolean
);

CREATE TABLE dsmfmxfer (
	time int4 NOT NULL,
	ip inet,
	username VARCHAR(256),
	cmd VARCHAR(16),
	filesize int8,
	filename text,
        isdir boolean
);

CREATE TABLE webdavxfer (
	time int4 NOT NULL,
	ip inet,
	username VARCHAR(256),
	cmd VARCHAR(16),
	filesize int8,
	filename text,
	isdir boolean
);

CREATE TABLE smbxfer (
	time int4 NOT NULL,
	ip inet,
	username VARCHAR(256),
	cmd VARCHAR(16),
	filesize int8,
	filename text,
	isdir boolean
);

CREATE TABLE afpxfer (
	time int4 NOT NULL,
	ip inet,
	username VARCHAR(256),
	cmd VARCHAR(16),
	filesize int8,
	filename text,
	isdir boolean
);

CREATE TABLE tftpxfer (
	time int4 NOT NULL,
	ip inet,
	username VARCHAR(256),
	cmd VARCHAR(16),
	filesize int8,
	filename text,
	isdir boolean
);
