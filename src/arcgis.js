// Thin client for the City of Seattle's public ArcGIS Online feature services
// (the same data behind SDOT's parking map). No API key is required.

export const SEATTLE_ARCGIS = 'https://services.arcgis.com/ZOyb2t4B0UYuYNYH/arcgis/rest/services';

/** SDOT blockface parking categories: one line per side of each block. */
export const PARKING_CATEGORIES_LAYER = `${SEATTLE_ARCGIS}/Parking_Categories/FeatureServer/0`;

/** Restricted Parking Zone (RPZ) boundaries, with zone name and hours in effect. */
export const RPZ_ZONES_LAYER = `${SEATTLE_ARCGIS}/Restricted_Parking_Zone_Areas/FeatureServer/4`;

const TIMEOUT_MS = 10_000;

/**
 * Run a spatial query against a feature layer: features within `radiusMeters`
 * of a point (or intersecting it when radiusMeters is 0).
 */
export async function queryNear(layerUrl, { lat, lon, radiusMeters, outFields, returnGeometry = true }, fetchImpl = fetch) {
  const params = new URLSearchParams({
    geometry: `${lon},${lat}`,
    geometryType: 'esriGeometryPoint',
    inSR: '4326',
    outSR: '4326',
    spatialRel: 'esriSpatialRelIntersects',
    outFields: outFields.join(','),
    returnGeometry: String(returnGeometry),
    f: 'json',
  });
  if (radiusMeters > 0) {
    params.set('distance', String(radiusMeters));
    params.set('units', 'esriSRUnit_Meter');
  }
  const res = await fetchImpl(`${layerUrl}/query`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: params.toString(),
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!res.ok) throw new Error(`Seattle GIS query failed: HTTP ${res.status}`);
  const body = await res.json();
  if (body.error) throw new Error(`Seattle GIS query failed: ${body.error.message ?? JSON.stringify(body.error)}`);
  return body.features ?? [];
}
