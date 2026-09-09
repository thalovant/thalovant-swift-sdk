// Independent Node Noise responder for an explicit loopback integration run.
// Usage: node peer.mjs /path/to/built/thalovant-node-sdk
import {createRequire} from 'node:module';
import {createServer} from 'node:http';
import {join, resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {randomBytes} from 'node:crypto';
const root = resolve(process.argv[2]), req = createRequire(join(root, 'package.json'));
const WebSocketServer = req('ws').WebSocketServer ?? req('ws').Server;
const n = await import(pathToFileURL(join(root, 'dist/src/noise.js')));
const staticKey = randomBytes(32), nodeID = 'swift-loopback-fixture';
const psk = n.derivePsk('fixture-password', nodeID);
let pinned, connections = 0, exchanges = 0, barriers = 0, closedBatches = 0, finished = false;
const pending = new Map();
const httpServer = createServer((request, response) => {
  response.setHeader('Content-Type', 'application/json');
  if (request.method === 'GET' && request.url === '/fixture/status') {
    response.end(JSON.stringify({connections, barriers, closedBatches}));
    return;
  }
  const batch = Number(/^\/fixture\/release\/([12])$/.exec(request.url)?.[1]);
  if (request.method !== 'POST' || batch !== barriers + 1 || connections !== batch ||
      closedBatches !== batch - 1 || exchanges !== (batch - 1) * 3 || !pending.has(batch)) {
    response.writeHead(409).end(JSON.stringify({connections, barriers}));
    finish(new Error('invalid concurrent-connect barrier'));
    return;
  }
  barriers++;
  const release = pending.get(batch);
  pending.delete(batch);
  release();
  response.end(JSON.stringify({connections, barriers}));
});
const server = new WebSocketServer({server: httpServer});
const timer = setTimeout(() => {
  finish(new Error(`loopback fixture timed out: connections=${connections}, barriers=${barriers}, exchanges=${exchanges}, closed=${closedBatches}`));
}, 60000);
timer.unref();

function finish(error) {
  if (finished) return;
  finished = true;
  clearTimeout(timer);
  if (error) {
    console.error('loopback peer rejected:', error.message);
    process.exitCode = 1;
  } else {
    console.log('Node peer verified two three-caller barriers, exactly two XX/KK connections and six encrypted exchanges');
  }
  server.close();
  for (const client of server.clients) client.terminate();
  httpServer.close();
  httpServer.closeIdleConnections();
}

server.on('connection', socket => {
  const batch = ++connections;
  if (batch > 2 || barriers !== batch - 1 || closedBatches !== batch - 1 || exchanges !== (batch - 1) * 3) {
    finish(new Error('unexpected extra or overlapping connection'));
    return;
  }
  const hello = {node_id: nodeID, pubkey: 'fixture', label: 'café/voice'};
  const offer = {max_protocol_version: 3, binarize: true, encodings: ['JSON-HEX'], ciphers: ['AES-GCM'],
    noise: {patterns: pinned ? ['XXpsk2', 'KKpsk0'] : ['XXpsk2'], suites: ['25519_ChaChaPoly_SHA256', '25519_AESGCM_SHA256']}};
  let handshake, session, released = false;
  const received = new Set();
  pending.set(batch, () => {
    released = true;
    socket.send(JSON.stringify({msg_type: 'hello', payload: hello}));
    socket.send(JSON.stringify({msg_type: 'shake', payload: offer}));
  });
  socket.on('message', (bytes, binary) => {
    try {
      if (!released) throw new Error('handshake started before the three-caller barrier');
      if (session) {
        if (!binary) throw new Error('unencrypted transport');
        const frame = session.decryptFrame(bytes);
        if (!frame.complete) return;
        const message = JSON.parse(Buffer.from(frame.payload));
        if (message.msg_type === 'hello') return;
        if (message.msg_type !== 'bus' || message.payload.type !== 'fixture.ping') throw new Error('unexpected application frame');
        const sequence = message.payload.data.n;
        if (![0, 1, 2].includes(sequence) || received.has(sequence) || connections !== batch || barriers !== batch) {
          throw new Error('duplicate exchange or wrong connection batch');
        }
        received.add(sequence);
        exchanges++;
        const reply = Buffer.from(JSON.stringify({msg_type: 'bus', payload: {type: 'fixture.pong', data: message.payload.data, context: {}}}));
        for (const chunk of session.encryptMessage(reply, true)) socket.send(chunk, {binary: true});
        return;
      }
      if (binary) throw new Error('binary before handshake');
      const envelope = JSON.parse(bytes), params = envelope.payload.noise;
      if (!handshake) {
        const expected = pinned ? 'KKpsk0' : 'XXpsk2';
        if (params.pattern !== expected) throw new Error('wrong selected pattern');
        if (params.suite !== '25519_AESGCM_SHA256') throw new Error('wrong selected suite');
        handshake = new n.NoiseHandshake(params.pattern, params.suite, psk,
          n.buildPrologue(hello, offer, n.noiseProtocolName(params.pattern, params.suite)), staticKey, pinned, false);
        handshake.readMessage(Buffer.from(params.msg, 'hex'));
        const reply = handshake.writeMessage(Buffer.from('{"encoding":"JSON-HEX"}'));
        socket.send(JSON.stringify({msg_type: 'shake', payload: {noise: {msg: Buffer.from(reply).toString('hex')}}}));
      } else handshake.readMessage(Buffer.from(params.msg, 'hex'));
      if (handshake.isFinished) {
        session = handshake.intoSession();
        pinned = Buffer.from(session.remoteStaticKey, 'hex');
      }
    } catch (error) { finish(error); }
  });
  socket.on('error', finish);
  socket.on('close', () => {
    if (finished) return;
    if (!released || received.size !== 3 || connections !== batch || barriers !== batch || exchanges !== batch * 3) {
      finish(new Error('connection closed before its barrier and three exchanges completed'));
      return;
    }
    closedBatches++;
    if (closedBatches === 2) finish();
  });
});
httpServer.on('error', finish);
httpServer.listen(0, '127.0.0.1', () => console.log(`ws://127.0.0.1:${httpServer.address().port}`));
