CREATE TABLE tftpxfer (
	time int4 NOT NULL,
	ip inet,
	username VARCHAR(256),
	cmd VARCHAR(16),
	filesize int8,
	filename text,
	isdir boolean
);
