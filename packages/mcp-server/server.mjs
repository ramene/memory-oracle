#!/usr/bin/env node
// memory-oracle MCP server — stdio transport for Claude Desktop / Claude Code / Cline / etc.
// Exposes memory_search, memory_cite, memory_supersede, memory_stats, memory_info as MCP tools.
//
// Run via: node packages/mcp-server/server.mjs
// Or wire into ~/.claude/settings.json:
//   "mcpServers": { "memory-oracle": { "command": "node", "args": ["/path/to/server.mjs"] } }

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { HANDLERS, TOOL_DEFINITIONS } from '../core/handlers.mjs';

const server = new Server(
  { name: 'memory-oracle', version: '0.1.0' },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: Object.entries(TOOL_DEFINITIONS).map(([name, def]) => ({
    name,
    description: def.description,
    inputSchema: def.inputSchema,
  })),
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;
  const handler = HANDLERS[name];
  if (!handler) {
    return { content: [{ type: 'text', text: `Unknown tool: ${name}` }], isError: true };
  }
  try {
    const result = await handler(args || {});
    const text = typeof result === 'string' ? result : (result.results || JSON.stringify(result, null, 2));
    return { content: [{ type: 'text', text }] };
  } catch (e) {
    return { content: [{ type: 'text', text: `Error: ${e.message}` }], isError: true };
  }
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error('[memory-oracle MCP] connected via stdio');
}

main().catch(err => {
  console.error('[memory-oracle MCP] fatal:', err);
  process.exit(1);
});
