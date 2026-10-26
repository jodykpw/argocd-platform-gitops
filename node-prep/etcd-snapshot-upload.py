#!/usr/bin/env python3
"""Upload one file to an S3 bucket (Garage) with SigV4, no dependencies. Usage: etcd-snapshot-upload.py <file>
Reads S3_ENDPOINT, S3_BUCKET, S3_KEY_ID, S3_SECRET from /etc/etcd-snapshot-s3.env. Stores it as <hostname>/<file name>
and checks the stored size with a HEAD request. Exit 0 only if the object is there with the right size."""
import datetime, hashlib, hmac, http.client, os, socket, sys, urllib.parse

ENV = "/etc/etcd-snapshot-s3.env"
REGION = "garage"


def load_env(path):
    cfg = {}
    for line in open(path):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip()
    return cfg


def _hmac(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def request(cfg, method, path, fileobj=None, size=0):
    host = urllib.parse.urlparse(cfg["S3_ENDPOINT"]).netloc
    now = datetime.datetime.now(datetime.timezone.utc)
    amz, day = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
    payload = "UNSIGNED-PAYLOAD"
    hdrs = {"host": host, "x-amz-content-sha256": payload, "x-amz-date": amz}
    names = sorted(hdrs)
    canon = "\n".join([
        method, urllib.parse.quote(path, safe="/-_.~"), "",
        "".join("%s:%s\n" % (k, hdrs[k]) for k in names), ";".join(names), payload])
    scope = "%s/%s/s3/aws4_request" % (day, REGION)
    sts = "\n".join(["AWS4-HMAC-SHA256", amz, scope, hashlib.sha256(canon.encode()).hexdigest()])
    k = hmac.new(("AWS4" + cfg["S3_SECRET"]).encode(), day.encode(), hashlib.sha256).digest()
    for part in (REGION, "s3", "aws4_request"):
        k = _hmac(k, part)
    sig = hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()
    send = {"x-amz-content-sha256": payload, "x-amz-date": amz,
            "Authorization": "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s"
                             % (cfg["S3_KEY_ID"], scope, ";".join(names), sig)}
    if fileobj is not None:
        send["Content-Length"] = str(size)
    conn = http.client.HTTPConnection(host, timeout=600)
    conn.request(method, urllib.parse.quote(path, safe="/-_.~"), body=fileobj, headers=send)
    r = conn.getresponse()
    body = r.read()
    return r.status, dict(r.getheaders()), body


def main():
    src = sys.argv[1]
    cfg = load_env(ENV)
    size = os.path.getsize(src)
    path = "/%s/%s/%s" % (cfg["S3_BUCKET"], socket.gethostname().split(".")[0], os.path.basename(src))
    with open(src, "rb") as f:
        status, _, body = request(cfg, "PUT", path, f, size)
    if status != 200:
        sys.exit("upload failed: HTTP %s %s" % (status, body[:200]))
    status, h, _ = request(cfg, "HEAD", path)
    got = {k.lower(): v for k, v in h.items()}.get("content-length")
    if status != 200 or got != str(size):
        sys.exit("verify failed: HTTP %s size %s expected %s" % (status, got, size))
    print("uploaded %s (%d bytes)" % (path, size))


if __name__ == "__main__":
    main()
