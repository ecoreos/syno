#!/usr/bin/php -d open_basedir=/usr/syno/bin/ddns
<?php

if ($argc !== 5) {
    echo 'badparam';
    exit();
}

$account = str_replace('@', '%40', $argv[1]);
$pwd = (string)$argv[2];
$hostname = (string)$argv[3];
$ip = (string)$argv[4];

// only for IPv4 format
if (!filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
    echo "badparam";
    exit();
}

$url = 'https://'.$account.':'.$pwd.'@updates.dnsomatic.com/nic/update?hostname='.$hostname.'&myip='.$ip.'&wildcard=NOCHG&mx=NOCHG&backmx=NOCHG';

$req = curl_init();
curl_setopt($req, CURLOPT_URL, $url);
$res = curl_exec($req);
curl_close($req);


