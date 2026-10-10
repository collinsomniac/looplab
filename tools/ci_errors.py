import os, json, urllib.request, re, sys
class N(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, h, new):
        r = super().redirect_request(req, fp, code, msg, h, new)
        r.headers.pop("Authorization", None); r.unredirected_hdrs.pop("Authorization", None); return r
o = urllib.request.build_opener(N); tok = os.environ["GITHUB_TOKEN"]
def api(p, raw=False):
    req = urllib.request.Request(f"https://api.github.com/repos/collinsomniac/looplab/{p}",
                                 headers={"Authorization": f"Bearer {tok}", "Accept": "application/vnd.github+json"})
    d = o.open(req, timeout=120).read()
    return d.decode("utf-8", "replace") if raw else json.loads(d)
run = api("actions/runs?per_page=1")["workflow_runs"][0]
job = api(f"actions/runs/{run['id']}/jobs")["jobs"][0]
log = api(f"actions/jobs/{job['id']}/logs", raw=True)
seen = []
for line in log.splitlines():
    line = re.sub(r"^\S*Z ", "", line)
    if re.search(r"\berror:", line) and "grep -E" not in line and line not in seen:
        seen.append(line)
for l in seen[:int(sys.argv[1]) if len(sys.argv) > 1 else 25]: print(l[:260])
