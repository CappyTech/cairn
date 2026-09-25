/// <reference path="../pb_data/types.d.ts" />
// Snap a History trip to roads on this server's own router (Valhalla), so the
// trip's coordinates don't go to a third party.
//
//   POST /api/cairn/snap   (signed-in users only)
//   { "mode": "walk" | "cycle" | "vehicle",
//     "points": [[lat, lng, epochSeconds?], ...] }
//   → 200 { "line": [[lat, lng], ...] }
//   → 503 when the router isn't set up / is down / can't match the trip, so
//         the app falls back to the public OSM router.
//
// The router lives on the internal Docker network (see
// deploy/docker-compose.yml); CAIRN_VALHALLA_URL points at it. Nothing is
// stored or logged here: the points are forwarded and the line returned.
//
// With a time on every point (strictly increasing), Valhalla uses them to
// rule out routes that couldn't have been travelled in between.
//
// NOTE: each hook handler runs in an isolated JS runtime, so all logic is
// inline.
routerAdd("POST", "/api/cairn/snap", (e) => {
  const body = e.requestInfo().body || {};
  const costing = { walk: "pedestrian", cycle: "bicycle", vehicle: "auto" }[body.mode];
  const raw = body.points;
  if (!costing || !Array.isArray(raw) || raw.length < 2 || raw.length > 5000) {
    throw new BadRequestError("Expected a mode and 2–5000 points.");
  }
  const shape = [];
  let timed = true;
  let lastTime = -Infinity;
  for (const p of raw) {
    const lat = Number(p && p[0]);
    const lon = Number(p && p[1]);
    if (!isFinite(lat) || !isFinite(lon) || Math.abs(lat) > 90 || Math.abs(lon) > 180) {
      throw new BadRequestError("Bad point.");
    }
    const t = p.length > 2 ? Number(p[2]) : NaN;
    if (!isFinite(t) || t <= lastTime) timed = false;
    else lastTime = t;
    shape.push(isFinite(t) ? { lat: lat, lon: lon, time: t } : { lat: lat, lon: lon });
  }
  // Times only help if every point has one, in order; otherwise drop them.
  if (!timed) for (const pt of shape) delete pt.time;

  const base = $os.getenv("CAIRN_VALHALLA_URL") || "http://cairn-valhalla:8002";
  let res;
  try {
    res = $http.send({
      url: base + "/trace_attributes",
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        shape: shape,
        costing: costing,
        shape_match: "map_snap",
        use_timestamps: timed,
        // Background fixes can be minutes (kilometres) apart.
        trace_options: { search_radius: 50, breakage_distance: 5000 },
        filters: { attributes: ["shape"], action: "include" },
      }),
      timeout: 20,
    });
  } catch (err) {
    throw new ApiError(503, "Router unavailable.");
  }
  const encoded = res.statusCode === 200 && res.json ? res.json.shape : null;
  if (typeof encoded !== "string" || encoded.length === 0) {
    throw new ApiError(503, "Router couldn't match this trip.");
  }

  // Valhalla shapes are Google-encoded polylines at 1e6 precision.
  const line = [];
  let i = 0, lat = 0, lng = 0;
  while (i < encoded.length) {
    for (let k = 0; k < 2; k++) {
      let shift = 0, result = 0, b;
      do {
        b = encoded.charCodeAt(i++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      const delta = result & 1 ? ~(result >> 1) : result >> 1;
      if (k === 0) lat += delta; else lng += delta;
    }
    line.push([lat / 1e6, lng / 1e6]);
  }
  if (line.length < 2) throw new ApiError(503, "Router couldn't match this trip.");
  return e.json(200, { line: line });
}, $apis.requireAuth());
