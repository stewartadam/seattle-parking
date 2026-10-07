// OpenAPI description of the REST API, for a ChatGPT custom GPT "Action".

const locationParams = [
  { name: 'lat', in: 'query', schema: { type: 'number' }, description: 'Latitude, if known.' },
  { name: 'lon', in: 'query', schema: { type: 'number' }, description: 'Longitude, if known.' },
  {
    name: 'address',
    in: 'query',
    schema: { type: 'string' },
    description: 'Where the user is in words, e.g. "Broadway and Pine". Used when lat/lon are not given. Seattle is assumed.',
  },
  { name: 'permitZone', in: 'query', schema: { type: 'string' }, description: "The user's RPZ permit zone, if any." },
];

const speechResponse = {
  200: {
    description: 'Answer. Read `speech` aloud to the user.',
    content: {
      'application/json': {
        schema: { type: 'object', properties: { speech: { type: 'string' } }, additionalProperties: true },
      },
    },
  },
};

export function openApiSpec(baseUrl, { requireKey = false } = {}) {
  return {
    openapi: '3.1.0',
    info: {
      title: 'Seattle Parking',
      version: '0.1.0',
      description: "Street parking rules and nearest legal parking in Seattle, from the City of Seattle's SDOT blockface data.",
    },
    servers: [{ url: baseUrl }],
    paths: {
      '/api/here': {
        get: {
          operationId: 'parkingRulesHere',
          summary: 'Parking rules on the street at a location, right now',
          parameters: locationParams,
          responses: speechResponse,
        },
      },
      '/api/nearby': {
        get: {
          operationId: 'findNearestParking',
          summary: 'Closest blocks where the user can legally park right now',
          parameters: [
            ...locationParams,
            { name: 'minMinutes', in: 'query', schema: { type: 'integer' }, description: 'Minimum time the user needs to stay.' },
            { name: 'freeOnly', in: 'query', schema: { type: 'boolean' }, description: 'Only free parking.' },
            { name: 'radiusMeters', in: 'query', schema: { type: 'integer' }, description: 'Search radius (default 500, max 1500).' },
            { name: 'limit', in: 'query', schema: { type: 'integer' }, description: 'Number of results (default 3).' },
          ],
          responses: speechResponse,
        },
      },
    },
    ...(requireKey && {
      components: { securitySchemes: { apiKey: { type: 'apiKey', in: 'header', name: 'X-API-Key' } } },
      security: [{ apiKey: [] }],
    }),
  };
}
