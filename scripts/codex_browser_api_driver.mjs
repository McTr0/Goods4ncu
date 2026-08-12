#!/usr/bin/env node
import { randomUUID } from 'node:crypto';

const DEFAULT_BASE_URL = 'http://127.0.0.1:3000';
const PASSWORD = process.env.GOOD4NCU_TEST_PASSWORD || 'Test1234';

const USERS = {
  admin: {
    id: 'a0000000-0000-0000-0000-000000000001',
    username: 'admin',
    password: PASSWORD,
  },
  buyer1: {
    id: 'b0000000-0000-0000-0000-000000000001',
    username: 'buyer1',
    password: PASSWORD,
  },
  buyer2: {
    id: 'b0000000-0000-0000-0000-000000000002',
    username: 'buyer2',
    password: PASSWORD,
  },
  seller1: {
    id: 's0000000-0000-0000-0000-000000000001',
    username: 'seller1',
    password: PASSWORD,
  },
  seller2: {
    id: 's0000000-0000-0000-0000-000000000002',
    username: 'seller2',
    password: PASSWORD,
  },
};

const IDS = {
  iphoneListing: 'l0000000-0000-0000-0000-000000000001',
  mathBookListing: 'l0000000-0000-0000-0000-000000000002',
};

const SUPPORTED_COMMANDS = [
  'health',
  'personas',
  'r2-chat',
  'p0-chat',
  'spaces',
  'call-secret',
  'all',
];

function usage() {
  return `Goods4ncu Codex Browser API driver

Usage:
  node scripts/codex_browser_api_driver.mjs <command> [--base=http://127.0.0.1:3000] [--json]

Commands:
  health       Check /api/health.
  personas     Print seed persona usernames and ids.
  r2-chat      Exercise the two-user mail/realtime privacy journey and explicit acknowledgements.
  p0-chat      Prepare and assert one active buyer/seller chat with reply, reaction, hide, report.
  spaces       Prepare and assert one group plus one channel permission check.
  call-secret  Prepare and assert WebRTC signaling MVP plus Secret Chat ciphertext path.
  all          Run health, p0-chat, spaces, and call-secret.

Environment:
  GOOD4NCU_API_BASE       Backend base URL. Defaults to ${DEFAULT_BASE_URL}.
  GOOD4NCU_TEST_PASSWORD  Seed user password. Defaults to Test1234.
`;
}

function parseArgs(argv) {
  const args = [...argv];
  let command = 'health';
  let json = false;
  let baseUrl = process.env.GOOD4NCU_API_BASE || DEFAULT_BASE_URL;

  for (const arg of args) {
    if (arg === '--help' || arg === '-h') {
      return { help: true, command, baseUrl, json };
    }
    if (arg === '--json') {
      json = true;
      continue;
    }
    if (arg.startsWith('--base=')) {
      baseUrl = arg.slice('--base='.length).replace(/\/+$/, '');
      continue;
    }
    if (arg.startsWith('-')) {
      throw new Error(`Unknown option: ${arg}`);
    }
    command = arg;
  }

  if (!SUPPORTED_COMMANDS.includes(command)) {
    throw new Error(`Unknown command: ${command}`);
  }
  return { help: false, command, baseUrl: baseUrl.replace(/\/+$/, ''), json };
}

function nowLabel() {
  return new Date().toISOString().replace(/[:.]/g, '-');
}

function assert(condition, message, details = undefined) {
  if (!condition) {
    const suffix = details === undefined ? '' : `\n${JSON.stringify(details, null, 2)}`;
    throw new Error(`Assertion failed: ${message}${suffix}`);
  }
}

async function request(baseUrl, method, path, token, body, allowedStatuses = [200, 201]) {
  const headers = {};
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }
  let payload;
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    payload = JSON.stringify(body);
  }
  const url = `${baseUrl}${path}`;
  const response = await fetchWithHint(url, {
    method,
    headers,
    body: payload,
  });
  const text = await response.text();
  let data = text;
  if (text) {
    try {
      data = JSON.parse(text);
    } catch {
      data = text;
    }
  }
  const normalized = typeof data === 'object' && data !== null ? data : { body: data };
  normalized._status = response.status;
  if (!allowedStatuses.includes(response.status)) {
    throw new Error(
      `${method} ${path} returned ${response.status}\n${JSON.stringify(normalized, null, 2)}`,
    );
  }
  return normalized;
}

async function fetchWithHint(url, options = undefined) {
  try {
    return await fetch(url, options);
  } catch (error) {
    throw new Error(
      `Cannot reach ${url}. Start the backend with "cargo run" and check GOOD4NCU_API_BASE. Original error: ${error.message}`,
    );
  }
}

async function login(baseUrl, key) {
  const user = USERS[key];
  const data = await request(baseUrl, 'POST', '/api/auth/login', null, {
    username: user.username,
    password: user.password,
  });
  assert(data.token, `login did not return a token for ${user.username}`, data);
  return { ...user, token: data.token, refreshToken: data.refresh_token };
}

async function runHealth(baseUrl) {
  const response = await fetchWithHint(`${baseUrl}/api/health`);
  const text = await response.text();
  assert(response.ok, '/api/health should return 2xx', {
    status: response.status,
    body: text,
  });
  assert(text.trim() === 'OK', '/api/health should return OK', text);
  return { command: 'health', ok: true, status: response.status, body: text.trim() };
}

async function ensureActiveRealtime(baseUrl) {
  const buyer = await login(baseUrl, 'buyer1');
  const seller = await login(baseUrl, 'seller1');
  const label = nowLabel();
  const created = await request(baseUrl, 'POST', '/api/chat/conversations', buyer.token, {
    client_request_id: randomUUID(),
    recipient_id: seller.id,
    listing_id: IDS.iphoneListing,
    mode: 'realtime',
    subject: null,
    content: `Codex Browser realtime smoke ${label}: iphone still available?`,
  });

  let conversation = created.conversation;
  assert(conversation?.id, 'create conversation should return conversation.id', created);

  if (conversation.state === 'syn_sent') {
    conversation = await request(
      baseUrl,
      'POST',
      `/api/chat/conversations/${conversation.id}/respond`,
      seller.token,
      { decision: 'accept' },
    );
  }

  if (conversation.state === 'syn_ack') {
    conversation = await request(
      baseUrl,
      'POST',
      `/api/chat/conversations/${conversation.id}/ack`,
      buyer.token,
      {},
    );
  }

  assert(conversation.state === 'active', 'conversation should be active before message tests', {
    state: conversation.state,
    id: conversation.id,
  });

  return {
    buyer,
    seller,
    conversation,
    created: Boolean(created.created),
    mutualOpen: Boolean(created.mutual_open),
  };
}

function assertNoAttentionFields(value, path = '$') {
  if (Array.isArray(value)) {
    value.forEach((item, index) => assertNoAttentionFields(item, `${path}[${index}]`));
    return;
  }
  if (!value || typeof value !== 'object') return;
  for (const [key, nested] of Object.entries(value)) {
    assert(
      !['read_at', 'read_by', 'typing', 'online', 'last_seen'].includes(key),
      `privacy response must not expose ${key}`,
      { path: `${path}.${key}` },
    );
    assertNoAttentionFields(nested, `${path}.${key}`);
  }
}

async function runR2Chat(baseUrl) {
  const buyer = await login(baseUrl, 'buyer1');
  const seller = await login(baseUrl, 'seller1');
  const label = nowLabel();

  const realtimeCreated = await request(
    baseUrl,
    'POST',
    '/api/chat/conversations',
    buyer.token,
    {
      client_request_id: randomUUID(),
      recipient_id: seller.id,
      listing_id: IDS.iphoneListing,
      mode: 'realtime',
      subject: null,
      content: `R2 connection ${label}`,
    },
  );
  let realtime = realtimeCreated.conversation;
  assert(realtime?.id, 'R2 realtime creation should return a conversation', realtimeCreated);
  if (realtime.state === 'syn_sent') {
    realtime = await request(
      baseUrl,
      'POST',
      `/api/chat/conversations/${realtime.id}/respond`,
      seller.token,
      { decision: 'accept' },
    );
  }
  if (realtime.state === 'syn_ack') {
    realtime = await request(
      baseUrl,
      'POST',
      `/api/chat/conversations/${realtime.id}/ack`,
      buyer.token,
      {},
    );
  }
  assert(realtime.state === 'active', 'R2 realtime should be active after accept/ack', realtime);

  const message = await request(
    baseUrl,
    'POST',
    `/api/chat/conversations/${realtime.id}/messages`,
    buyer.token,
    {
      client_message_id: randomUUID(),
      content: `R2 explicit acknowledgement ${label}`,
      reply_to_message_id: null,
      image_base64: null,
      audio_base64: null,
      image_url: null,
      audio_url: null,
    },
  );
  assert(message.status === 'sent', 'server-accepted message should be sent', message);
  assertNoAttentionFields(message);

  let acknowledged = await request(
    baseUrl,
    'POST',
    `/api/chat/messages/${message.id}/acknowledgement`,
    seller.token,
    { kind: 'received' },
  );
  assert(
    acknowledged.acknowledgements?.some(
      (item) => item.user_id === seller.id && item.kind === 'received',
    ),
    'recipient should explicitly acknowledge receipt',
    acknowledged,
  );
  acknowledged = await request(
    baseUrl,
    'POST',
    `/api/chat/messages/${message.id}/acknowledgement`,
    seller.token,
    { kind: 'completed' },
  );
  assert(
    acknowledged.acknowledgements?.filter((item) => item.user_id === seller.id).length === 1 &&
      acknowledged.acknowledgements[0]?.kind === 'completed',
    'acknowledgement replacement should remain one explicit action',
    acknowledged,
  );
  const withdrawn = await request(
    baseUrl,
    'DELETE',
    `/api/chat/messages/${message.id}/acknowledgement`,
    seller.token,
  );
  assert(
    !withdrawn.acknowledgements?.some((item) => item.user_id === seller.id),
    'recipient should be able to withdraw the acknowledgement',
    withdrawn,
  );

  const closed = await request(
    baseUrl,
    'POST',
    `/api/chat/conversations/${realtime.id}/close`,
    buyer.token,
    {},
  );
  assert(closed.state === 'closed', 'explicit end should close the realtime session', closed);

  const mailCreated = await request(
    baseUrl,
    'POST',
    '/api/chat/conversations',
    buyer.token,
    {
      client_request_id: randomUUID(),
      recipient_id: seller.id,
      listing_id: IDS.iphoneListing,
      mode: 'mail',
      subject: `R2 mail ${label}`,
      content: 'No rush; please reply when convenient.',
    },
  );
  assert(
    mailCreated.conversation?.mode === 'mail',
    'mail should remain a separate asynchronous conversation',
    mailCreated,
  );
  assertNoAttentionFields(mailCreated);

  return {
    command: 'r2-chat',
    ok: true,
    realtimeConversationId: realtime.id,
    messageId: message.id,
    mailConversationId: mailCreated.conversation.id,
    finalRealtimeState: closed.state,
    acknowledgementLifecycle: ['received', 'completed', 'withdrawn'],
  };
}

async function runP0Chat(baseUrl) {
  const { buyer, seller, conversation, created, mutualOpen } = await ensureActiveRealtime(baseUrl);
  const buyerMessage = await request(
    baseUrl,
    'POST',
    `/api/chat/conversations/${conversation.id}/messages`,
    buyer.token,
    {
      client_message_id: randomUUID(),
      content: `Codex Browser buyer message ${nowLabel()}`,
      reply_to_message_id: null,
      image_base64: null,
      audio_base64: null,
      image_url: null,
      audio_url: null,
    },
  );

  const sellerMessage = await request(
    baseUrl,
    'POST',
    `/api/chat/conversations/${conversation.id}/messages`,
    seller.token,
    {
      client_message_id: randomUUID(),
      content: `Codex Browser seller reply ${nowLabel()}`,
      reply_to_message_id: buyerMessage.id,
      image_base64: null,
      audio_base64: null,
      image_url: null,
      audio_url: null,
    },
  );

  assert(
    sellerMessage.reply_preview?.id === buyerMessage.id,
    'seller reply should include a reply preview for the buyer message',
    sellerMessage,
  );

  const reacted = await request(
    baseUrl,
    'POST',
    `/api/chat/messages/${sellerMessage.id}/reaction`,
    buyer.token,
    { emoji: '👍' },
  );
  assert(
    reacted.reactions?.some((reaction) => reaction.emoji === '👍' && reaction.reacted_by_me),
    'reaction summary should include buyer thumbs-up',
    reacted.reactions,
  );

  const report = await request(
    baseUrl,
    'POST',
    `/api/chat/messages/${sellerMessage.id}/report`,
    buyer.token,
    {
      reason: 'codex_browser_smoke',
      details: 'Automated integration smoke report. No user-facing moderation decision expected.',
    },
  );
  assert(report.report_id, 'report should return report_id', report);

  const hidden = await request(
    baseUrl,
    'POST',
    `/api/chat/messages/${sellerMessage.id}/hide`,
    buyer.token,
    {},
  );
  assert(hidden.hidden === true, 'hide endpoint should confirm hidden=true', hidden);

  const buyerMessages = await request(
    baseUrl,
    'GET',
    `/api/chat/conversations/${conversation.id}/messages?limit=50&offset=0`,
    buyer.token,
  );
  const sellerMessages = await request(
    baseUrl,
    'GET',
    `/api/chat/conversations/${conversation.id}/messages?limit=50&offset=0`,
    seller.token,
  );

  assert(
    !buyerMessages.messages.some((message) => message.id === sellerMessage.id),
    'hidden message should disappear only for the hider',
    buyerMessages.messages,
  );
  assert(
    sellerMessages.messages.some((message) => message.id === sellerMessage.id),
    'hidden message should remain visible for the other member',
    sellerMessages.messages,
  );

  return {
    command: 'p0-chat',
    ok: true,
    created,
    mutualOpen,
    conversationId: conversation.id,
    buyerMessageId: buyerMessage.id,
    sellerMessageId: sellerMessage.id,
    reportId: report.report_id,
  };
}

async function runSpaces(baseUrl) {
  const owner = await login(baseUrl, 'buyer1');
  const member = await login(baseUrl, 'seller1');
  const label = nowLabel();

  const group = await request(baseUrl, 'POST', '/api/chat/spaces', owner.token, {
    kind: 'group',
    name: `Codex Browser group ${label}`,
    description: 'Integration group for Codex Browser acceptance.',
  });
  await request(baseUrl, 'POST', `/api/chat/spaces/${group.id}/members`, owner.token, {
    user_id: member.id,
    role: 'member',
  });
  const groupMessage = await request(
    baseUrl,
    'POST',
    `/api/chat/spaces/${group.id}/messages`,
    member.token,
    {
      client_message_id: randomUUID(),
      content: `Group hello from seller ${label}`,
      reply_to_message_id: null,
    },
  );

  const channel = await request(baseUrl, 'POST', '/api/chat/spaces', owner.token, {
    kind: 'channel',
    name: `Codex Browser channel ${label}`,
    description: 'Integration channel for permission checks.',
  });
  await request(baseUrl, 'POST', `/api/chat/spaces/${channel.id}/members`, owner.token, {
    user_id: member.id,
    role: 'member',
  });
  const channelMessage = await request(
    baseUrl,
    'POST',
    `/api/chat/spaces/${channel.id}/messages`,
    owner.token,
    {
      client_message_id: randomUUID(),
      content: `Channel announcement ${label}`,
      reply_to_message_id: null,
    },
  );
  const forbidden = await request(
    baseUrl,
    'POST',
    `/api/chat/spaces/${channel.id}/messages`,
    member.token,
    {
      client_message_id: randomUUID(),
      content: 'This member post should be forbidden in a channel.',
      reply_to_message_id: null,
    },
    [403],
  );

  assert(forbidden._status === 403, 'channel member should not be able to post', forbidden);

  return {
    command: 'spaces',
    ok: true,
    groupId: group.id,
    groupMessageId: groupMessage.id,
    channelId: channel.id,
    channelMessageId: channelMessage.id,
    forbiddenStatus: forbidden._status,
  };
}

async function runCallSecret(baseUrl) {
  const { buyer, seller, conversation } = await ensureActiveRealtime(baseUrl);
  const label = nowLabel();
  const call = await request(baseUrl, 'POST', '/api/chat/calls', buyer.token, {
    conversation_id: conversation.id,
    media: 'audio',
    offer_sdp: `v=0\ns=Codex Browser offer ${label}`,
  });
  assert(call.state === 'ringing', 'new call should start ringing', call);

  const answered = await request(
    baseUrl,
    'POST',
    `/api/chat/calls/${call.id}/answer`,
    seller.token,
    { answer_sdp: `v=0\ns=Codex Browser answer ${label}` },
  );
  assert(answered.state === 'accepted', 'answered call should be accepted', answered);

  const ended = await request(
    baseUrl,
    'POST',
    `/api/chat/calls/${call.id}/end`,
    buyer.token,
    { reason: 'codex_browser_smoke' },
  );
  assert(ended.state === 'ended', 'ended call should be ended', ended);

  const secret = await request(baseUrl, 'POST', '/api/chat/secret-sessions', buyer.token, {
    recipient_id: seller.id,
    initiator_key_fingerprint: `buyer-fp-${label}`,
    recipient_key_fingerprint: `seller-fp-${label}`,
    expires_at: null,
  });

  const secretMessage = await request(
    baseUrl,
    'POST',
    `/api/chat/secret-sessions/${secret.id}/messages`,
    buyer.token,
    {
      client_message_id: randomUUID(),
      ciphertext: Buffer.from(`ciphertext ${label}`).toString('base64'),
      nonce: Buffer.from(`nonce ${label}`).toString('base64'),
      key_fingerprint: `buyer-fp-${label}`,
      expires_at: null,
    },
  );

  const secretMessages = await request(
    baseUrl,
    'GET',
    `/api/chat/secret-sessions/${secret.id}/messages?limit=10&offset=0`,
    seller.token,
  );
  assert(
    Array.isArray(secretMessages) &&
      secretMessages.some((message) => message.id === secretMessage.id && message.ciphertext),
    'recipient should see stored ciphertext, not plaintext',
    secretMessages,
  );

  return {
    command: 'call-secret',
    ok: true,
    conversationId: conversation.id,
    callId: call.id,
    secretSessionId: secret.id,
    secretMessageId: secretMessage.id,
  };
}

async function runAll(baseUrl) {
  const results = [];
  results.push(await runHealth(baseUrl));
  results.push(await runP0Chat(baseUrl));
  results.push(await runSpaces(baseUrl));
  results.push(await runCallSecret(baseUrl));
  return { command: 'all', ok: true, results };
}

function personas() {
  return {
    command: 'personas',
    password: PASSWORD,
    users: Object.fromEntries(
      Object.entries(USERS).map(([key, user]) => [
        key,
        { id: user.id, username: user.username },
      ]),
    ),
  };
}

function printResult(result, json) {
  if (json) {
    console.log(JSON.stringify(result, null, 2));
    return;
  }
  console.log(JSON.stringify(result, null, 2));
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    console.log(usage());
    return;
  }

  let result;
  switch (options.command) {
    case 'health':
      result = await runHealth(options.baseUrl);
      break;
    case 'personas':
      result = personas();
      break;
    case 'r2-chat':
      result = await runR2Chat(options.baseUrl);
      break;
    case 'p0-chat':
      result = await runP0Chat(options.baseUrl);
      break;
    case 'spaces':
      result = await runSpaces(options.baseUrl);
      break;
    case 'call-secret':
      result = await runCallSecret(options.baseUrl);
      break;
    case 'all':
      result = await runAll(options.baseUrl);
      break;
    default:
      throw new Error(`Unhandled command: ${options.command}`);
  }
  printResult({ baseUrl: options.baseUrl, ...result }, options.json);
}

main().catch((error) => {
  console.error(error?.stack || String(error));
  process.exitCode = 1;
});
