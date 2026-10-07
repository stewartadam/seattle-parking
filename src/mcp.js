// MCP server exposing the two parking tools, for ChatGPT (connectors /
// developer mode), Claude, or any other MCP client.

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { UserError, nearestParking, parkingRulesHere } from './tools.js';

const location = {
  lat: z.number().optional().describe('Latitude of the user, if known (e.g. from the device).'),
  lon: z.number().optional().describe('Longitude of the user, if known.'),
  address: z
    .string()
    .optional()
    .describe('Where the user is, in words (e.g. "Broadway and Pine" or "1520 Pike Pl"). Used when lat/lon are not available. Seattle is assumed.'),
  permitZone: z.string().optional().describe("The user's Seattle RPZ permit zone number, if they have one."),
};

function asToolResult(fn) {
  return async (args) => {
    try {
      const result = await fn(args);
      return {
        content: [{ type: 'text', text: `${result.speech}\n\n${JSON.stringify(result)}` }],
        structuredContent: result,
      };
    } catch (err) {
      return { isError: true, content: [{ type: 'text', text: err instanceof UserError ? err.message : `Lookup failed: ${err.message}` }] };
    }
  };
}

export function createMcpServer() {
  const server = new McpServer({ name: 'seattle-parking', version: '0.1.0' });

  server.registerTool(
    'parking_rules_here',
    {
      title: 'Parking rules here',
      description:
        "Explain the street parking rules at a location in Seattle right now: paid/free, rate, time limit, RPZ permit zone, and rush-hour tow-away restrictions, for each side of the street. Uses the City of Seattle's SDOT blockface data. Read the `speech` field aloud.",
      inputSchema: location,
      annotations: { readOnlyHint: true, openWorldHint: true },
    },
    asToolResult(parkingRulesHere),
  );

  server.registerTool(
    'find_nearest_parking',
    {
      title: 'Find nearest parking',
      description:
        "Find the closest Seattle street blocks where the user can legally park right now, sorted by distance, with cost, time limit and walking direction. Uses the City of Seattle's SDOT blockface data. Read the `speech` field aloud.",
      inputSchema: {
        ...location,
        minMinutes: z.number().optional().describe('Only return places where the user can stay at least this many minutes.'),
        freeOnly: z.boolean().optional().describe('Only return places that are free right now.'),
        radiusMeters: z.number().optional().describe('Search radius in meters (default 500, max 1500).'),
        limit: z.number().optional().describe('How many places to return (default 3, max 10).'),
      },
      annotations: { readOnlyHint: true, openWorldHint: true },
    },
    asToolResult(nearestParking),
  );

  return server;
}
