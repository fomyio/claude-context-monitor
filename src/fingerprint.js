/**
 * fingerprint.js — Context summarizer for haiku input
 * Extracts a lightweight (400-600 token) representation of the recent session
 * from the JSONL transcript to send to Claude Haiku for relevance evaluation.
 */

'use strict';

const fs = require('fs');

/**
 * Parses the transcript and returns a short formatted string
 * summarizing the most recent turns.
 * 
 * @param {string} transcriptPath 
 * @param {number} maxHumanTurns default 5
 * @returns {string} The fingerprint text
 */
function buildFingerprint(transcriptPath, maxHumanTurns = 5) {
  if (!transcriptPath || !fs.existsSync(transcriptPath)) {
    return 'No transcript available.';
  }

  const raw = fs.readFileSync(transcriptPath, 'utf8');
  const lines = raw.split('\n').filter(l => l.trim());

  let entries = [];
  for (const line of lines) {
    try {
      entries.push(JSON.parse(line));
    } catch (_) {}
  }

  // Filter down to valid user/assistant messages with content
  const messages = entries
    .map(e => e.message || e)
    .filter(m => (m.role === 'user' || m.role === 'assistant') && m.content)
    .map(m => {
      let text = '';
      if (typeof m.content === 'string') text = m.content;
      else if (Array.isArray(m.content)) {
        text = m.content.filter(b => b.type === 'text').map(b => b.text).join('\n');
      }
      return { role: m.role, text };
    })
    .filter(m => m.text.trim().length > 0);

  if (messages.length === 0) return 'Empty session.';

  // Extract the last assistant response (up to 300 chars to save tokens)
  let lastAssistant = null;
  for (let i = messages.length - 1; i >= 0; i--) {
    if (messages[i].role === 'assistant') {
      lastAssistant = messages[i].text.substring(0, 300);
      if (messages[i].text.length > 300) lastAssistant += '...[truncated]';
      break;
    }
  }

  // Extract the last N human turns (up to 150 chars each)
  const humanTurns = messages
    .filter(m => m.role === 'user')
    .slice(-maxHumanTurns)
    .map(m => {
      let t = m.text.substring(0, 150);
      if (m.text.length > 150) t += '...';
      return t;
    });

  let fingerprint = 'RECENT USER TURNS:\n';
  if (humanTurns.length === 0) {
    fingerprint += '(None)\n';
  } else {
    humanTurns.forEach((t, index) => {
      fingerprint += \`[Turn -\${humanTurns.length - index}]: \${t}\n\`;
    });
  }

  fingerprint += '\nLATEST ASSISTANT RESPONSE:\n';
  if (lastAssistant) {
    fingerprint += lastAssistant;
  } else {
    fingerprint += '(None)';
  }

  return fingerprint;
}

module.exports = { buildFingerprint };
