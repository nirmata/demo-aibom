import Anthropic from "@anthropic-ai/sdk";

const client = new Anthropic();

const tools: Anthropic.Tool[] = [
  {
    name: "web_search",
    description: "Search the web for current information",
    input_schema: {
      type: "object" as const,
      properties: { query: { type: "string" } },
      required: ["query"],
    },
  },
  {
    name: "sql_lookup",
    description: "Query the internal analytics database",
    input_schema: {
      type: "object" as const,
      properties: { query: { type: "string" } },
      required: ["query"],
    },
  },
  // ⚠ PROHIBITED: filesystem tool added — will be caught by AIBOM baseline diff
  {
    name: "filesystem",
    description: "Read and write files on the host filesystem",
    input_schema: {
      type: "object" as const,
      properties: {
        operation: { type: "string", enum: ["read", "write", "list"] },
        path: { type: "string" },
        content: { type: "string" },
      },
      required: ["operation", "path"],
    },
  },
];

async function handleToolCall(
  name: string,
  input: Record<string, string>
): Promise<string> {
  if (name === "web_search") return `Search results for: ${input.query}`;
  if (name === "sql_lookup") return `Query results for: ${input.query}`;
  if (name === "filesystem") return `File op: ${input.operation} ${input.path}`;
  throw new Error(`Unknown tool: ${name}`);
}

export async function runResearchAgent(prompt: string): Promise<string> {
  const messages: Anthropic.MessageParam[] = [
    { role: "user", content: prompt },
  ];

  while (true) {
    const response = await client.messages.create({
      model: "claude-3-5-sonnet-20241022",
      max_tokens: 4096,
      tools,
      messages,
    });

    if (response.stop_reason === "end_turn") {
      const textBlock = response.content.find((b) => b.type === "text");
      return textBlock && textBlock.type === "text" ? textBlock.text : "";
    }

    if (response.stop_reason === "tool_use") {
      messages.push({ role: "assistant", content: response.content });
      const toolResults: Anthropic.ToolResultBlockParam[] = [];
      for (const block of response.content) {
        if (block.type === "tool_use") {
          toolResults.push({
            type: "tool_result",
            tool_use_id: block.id,
            content: await handleToolCall(
              block.name,
              block.input as Record<string, string>
            ),
          });
        }
      }
      messages.push({ role: "user", content: toolResults });
    }
  }
}
