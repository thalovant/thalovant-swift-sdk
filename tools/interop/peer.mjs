// Independent Node Noise responder for an explicit loopback integration run.
// Usage: node peer.mjs /path/to/built/thalovant-node-sdk
import {createRequire} from 'node:module';
import {join,resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {randomBytes} from 'node:crypto';
const root=resolve(process.argv[2]),req=createRequire(join(root,'package.json'));
const WebSocketServer=req('ws').WebSocketServer ?? req('ws').Server;
const n=await import(pathToFileURL(join(root,'dist/src/noise.js')));
const staticKey=randomBytes(32),nodeID='swift-loopback-fixture';
const psk=n.derivePsk('fixture-password',nodeID);
let pinned,connections=0,exchanges=0;
const server=new WebSocketServer({host:'127.0.0.1',port:0});
server.on('listening',()=>console.log(`ws://127.0.0.1:${server.address().port}`));
server.on('connection',socket=>{
  connections++;
  const hello={node_id:nodeID,pubkey:'fixture',label:'café/voice'},offer={max_protocol_version:3,binarize:true,encodings:['JSON-HEX'],ciphers:['AES-GCM'],noise:{patterns:pinned?['XXpsk2','KKpsk0']:['XXpsk2'],suites:['25519_ChaChaPoly_SHA256','25519_AESGCM_SHA256']}};
  let handshake,session;
  socket.on('message',(bytes,binary)=>{
    try {
      if(session){
        if(!binary)throw new Error('unencrypted transport');
        const frame=session.decryptFrame(bytes);
        if(!frame.complete)return;
        const message=JSON.parse(Buffer.from(frame.payload));
        if(message.msg_type==='hello')return;
        if(message.msg_type!=='bus'||message.payload.type!=='fixture.ping')throw new Error('unexpected application frame');
        exchanges++;
        const reply=Buffer.from(JSON.stringify({msg_type:'bus',payload:{type:'fixture.pong',data:message.payload.data,context:{}}}));
        for(const chunk of session.encryptMessage(reply,true))socket.send(chunk,{binary:true});
        return;
      }
      if(binary)throw new Error('binary before handshake');
      const envelope=JSON.parse(bytes),params=envelope.payload.noise;
      if(!handshake){
        const expected=pinned?'KKpsk0':'XXpsk2';if(params.pattern!==expected)throw new Error('wrong selected pattern');
        if(params.suite!=='25519_AESGCM_SHA256')throw new Error('wrong selected suite');
        handshake=new n.NoiseHandshake(params.pattern,params.suite,psk,n.buildPrologue(hello,offer,n.noiseProtocolName(params.pattern,params.suite)),staticKey,pinned,false);
        handshake.readMessage(Buffer.from(params.msg,'hex'));
        const reply=handshake.writeMessage(Buffer.from('{"encoding":"JSON-HEX"}'));
        socket.send(JSON.stringify({msg_type:'shake',payload:{noise:{msg:Buffer.from(reply).toString('hex')}}}));
      }else handshake.readMessage(Buffer.from(params.msg,'hex'));
      if(handshake.isFinished){session=handshake.intoSession();pinned=Buffer.from(session.remoteStaticKey,'hex');}
    }catch(error){console.error('loopback peer rejected:',error.message);process.exitCode=1;socket.close();}
  });
  socket.send(JSON.stringify({msg_type:'hello',payload:hello}));
  socket.send(JSON.stringify({msg_type:'shake',payload:offer}));
  socket.on('close',()=>{if(connections===2&&exchanges===6){console.log('Node peer verified XX/KK and six encrypted exchanges');server.close();}});
});
setTimeout(()=>{if(exchanges!==6){console.error('loopback fixture timed out');process.exitCode=1;}server.close();for(const socket of server.clients)socket.terminate();},60000).unref();
