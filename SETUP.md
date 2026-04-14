# Setup: claude-context-monitor

## Required: Anthropic API Key

The plugin's semantic relevance evaluation uses Claude Haiku to detect topic drift and score compact recommendations. This requires an Anthropic API key.

### How it works

- **Cost:** ~$0.0005 per evaluation (200 tokens per call)
- **When it runs:** Only above 45% context usage
- **Monthly cost:** ~$0.05–0.50 depending on usage

### Setup options (pick one)

**Option 1: Inherited from Claude Code (automatic)**

If you're running Claude Code with `ANTHROPIC_API_KEY` in your environment, the plugin picks it up automatically. No setup needed.

**Option 2: Key file**

```bash
echo "sk-ant-..." > ~/.anthropic_key
chmod 600 ~/.anthropic_key
```

**Option 3: Custom command**

Set `anthropic_api_key_cmd` in `config.json` to any shell command that outputs your key:

```json
{
  "anthropic_api_key_cmd": "pass show anthropic/api-key"
}
```

### Disabling the evaluation

If you prefer to skip the Haiku evaluation entirely, set in `config.json`:

```json
{
  "relevance_eval_enabled": false
}
```

The token bar, desktop notifications, and status line will continue working without an API key. Only the topic drift detection and smart compact scoring require it.