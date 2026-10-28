import os

from anthropic import AnthropicBedrock

model = os.getenv("PARSER_MODEL", "us.anthropic.claude-sonnet-4-6")
client = AnthropicBedrock(aws_region="us-east-1")

msg = client.messages.create(
    model=model,
    max_tokens=1024,
    output_config={"effort": "low"},
    messages=[{"role": "user", "content": "In one sentence: what is an ISO week?"}],
)

print("Response:", next(b.text for b in msg.content if b.type == "text"))
print("Stop reason:", msg.stop_reason)
print(f"Usage: input={msg.usage.input_tokens}, output={msg.usage.output_tokens}")
