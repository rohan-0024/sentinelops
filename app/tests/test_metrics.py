from prometheus_client.parser import text_string_to_metric_families


def scrape(client) -> dict:
    r = client.get("/metrics")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("text/plain")
    samples = {}
    for family in text_string_to_metric_families(r.text):
        for s in family.samples:
            samples[(s.name, tuple(sorted(s.labels.items())))] = s.value
    return samples


def test_build_info_metric(client):
    s = scrape(client)
    key = ("app_build_info", (("environment", "test"), ("git_sha", "abc1234"), ("version", "1.2.3")))
    assert s[key] == 1.0


def test_requests_are_counted_by_route_template(client):
    client.post("/api/items", json={"name": "a", "quantity": 1})
    client.get("/api/items/1")
    client.get("/api/items/999")
    s = scrape(client)
    tmpl = "/api/items/{item_id}"
    assert s[("http_requests_total", (("method", "GET"), ("path", tmpl), ("status", "200")))] == 1
    assert s[("http_requests_total", (("method", "GET"), ("path", tmpl), ("status", "404")))] == 1
    assert s[("http_requests_total", (("method", "POST"), ("path", "/api/items"), ("status", "201")))] == 1
    assert s[("http_request_duration_seconds_count", (("method", "GET"), ("path", tmpl)))] == 2


def test_unmatched_routes_do_not_explode_cardinality(client):
    client.get("/does/not/exist/1")
    client.get("/does/not/exist/2")
    s = scrape(client)
    assert s[("http_requests_total", (("method", "GET"), ("path", "unmatched"), ("status", "404")))] == 2


def test_metrics_endpoint_is_not_self_counted(client):
    client.get("/metrics")
    s = scrape(client)
    assert not any(k[0] == "http_requests_total" and ("path", "/metrics") in k[1] for k in s)


def test_items_gauge(client):
    client.post("/api/items", json={"name": "a", "quantity": 1})
    client.post("/api/items", json={"name": "b", "quantity": 1})
    assert scrape(client)[("app_items_total", ())] == 2.0


def test_in_flight_returns_to_zero(client):
    client.get("/health")
    assert scrape(client)[("http_requests_in_flight", ())] == 0.0
