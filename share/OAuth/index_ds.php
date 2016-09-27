<!doctype html>
<head>
<title>Synology App</title>
</head>
<body>
<p> Connecting... </p>
<script language="JavaScript" type="text/javascript">

    var href = window.location.href;
    var index = href.indexOf('?');
    var querys = href.slice(index+1).split('&');
    var params={};
    var callback = function() {};
    for (var i=0;i<querys.length;i++) {
        var tmp = querys[i].split('=');
        params[tmp[0]] = tmp[1];
    }
    callback = params['callback'] ? window.opener[params['callback']] : callback;
    if (callback) {
        callback(params);
    }
    window.close();

</script>
</body>
</html>
