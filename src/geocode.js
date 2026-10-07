// Turn a spoken place ("Broadway and Pine", "Pike Place Market") into
// coordinates, for voice assistants that can't pass the phone's GPS location.

const GEOCODER = 'https://geocode.arcgis.com/arcgis/rest/services/World/GeocodeServer/findAddressCandidates';

// Rough box around Seattle, used to bias and sanity-check results.
const SEATTLE_EXTENT = { xmin: -122.46, ymin: 47.48, xmax: -122.22, ymax: 47.74 };

export async function geocode(address, fetchImpl = fetch) {
  const singleLine = /seattle/i.test(address) ? address : `${address}, Seattle, WA`;
  const params = new URLSearchParams({
    SingleLine: singleLine,
    maxLocations: '1',
    outFields: 'Match_addr',
    location: '-122.335,47.608',
    searchExtent: JSON.stringify({ ...SEATTLE_EXTENT, spatialReference: { wkid: 4326 } }),
    f: 'json',
  });
  const res = await fetchImpl(`${GEOCODER}?${params}`, { signal: AbortSignal.timeout(10_000) });
  if (!res.ok) throw new Error(`Geocoding failed: HTTP ${res.status}`);
  const body = await res.json();
  const best = body.candidates?.[0];
  if (!best || best.score < 80) return null;
  return { lat: best.location.y, lon: best.location.x, matched: best.address };
}
