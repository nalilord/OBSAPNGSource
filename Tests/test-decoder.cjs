// Node.js built-ins only. Pass the compiled DecodeProbe.exe and a scratch folder.
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const cp = require('node:child_process');
const assert = require('node:assert/strict');
const [probe, scratch] = process.argv.slice(2);
if (!probe || !scratch) throw new Error('Usage: node test-decoder.cjs DecodeProbe.exe scratch-folder');
fs.mkdirSync(scratch, { recursive: true });
const crcTable = Array.from({length:256}, (_,i) => {
  let c=i; for(let k=0;k<8;k++) c=c&1?0xedb88320^(c>>>1):c>>>1; return c>>>0;
});
function chunk(type,data=Buffer.alloc(0)) {
  const contents=Buffer.concat([Buffer.from(type),data]);
  let crc=0xffffffff; for(const b of contents) crc=crcTable[(crc^b)&255]^(crc>>>8);
  const out=Buffer.alloc(data.length+12); out.writeUInt32BE(data.length);
  contents.copy(out,4);out.writeUInt32BE((crc^0xffffffff)>>>0,out.length-4);return out;
}
const signature=Buffer.from([137,80,78,71,13,10,26,10]);
function imageData(width,height,pixels,channels=4) {
  const rows=Buffer.alloc((width*channels+1)*height);
  for(let y=0;y<height;y++)Buffer.from(pixels).copy(rows,y*(width*channels+1)+1,y*width*channels,(y+1)*width*channels);
  return zlib.deflateSync(rows);
}
function make({width,height,frames,plays=0,hiddenDefault=false,palette=null,transparency=null,declared=frames.length,depth=8,color=palette?3:6,interlace=0}) {
  const header=Buffer.alloc(13);header.writeUInt32BE(width);header.writeUInt32BE(height,4);header[8]=depth;header[9]=color;header[12]=interlace;
  const actl=Buffer.alloc(8);actl.writeUInt32BE(declared);actl.writeUInt32BE(plays,4);
  const chunks=[signature,chunk('IHDR',header),chunk('acTL',actl)];
  if(palette)chunks.push(chunk('PLTE',Buffer.from(palette)));
  if(transparency)chunks.push(chunk('tRNS',Buffer.from(transparency)));
  if(hiddenDefault)chunks.push(chunk('IDAT',imageData(width,height,Array(width*height).fill([255,0,0,255]).flat())));
  let sequence=0;
  frames.forEach((f,i)=>{
    const control=Buffer.alloc(26);control.writeUInt32BE(sequence++);control.writeUInt32BE(f.w||width,4);control.writeUInt32BE(f.h||height,8);
    control.writeUInt32BE(f.x||0,12);control.writeUInt32BE(f.y||0,16);control.writeUInt16BE(f.num??1,20);control.writeUInt16BE(f.den??10,22);
    control[24]=f.dispose||0;control[25]=f.blend||0;chunks.push(chunk('fcTL',control));
    const data=f.data??imageData(f.w||width,f.h||height,f.pixels,palette?1:4);
    if(i===0&&!hiddenDefault)chunks.push(chunk('IDAT',data));
    else{const prefix=Buffer.alloc(4);prefix.writeUInt32BE(sequence++);chunks.push(chunk('fdAT',Buffer.concat([prefix,data])));}
  });
  chunks.push(chunk('IEND'));return Buffer.concat(chunks);
}
let passed=0;
function run(name,bytes,expected=null,delays=null) {
  const file=path.join(scratch,name+'.apng'),out=path.join(scratch,name);
  fs.writeFileSync(file,bytes);
  const result=cp.spawnSync(probe,[file,out],{encoding:'utf8',windowsHide:true,timeout:10000});
  if(expected){
    assert.equal(result.status,0,`${name}: ${result.stdout} ${result.stderr}`);
    expected.forEach((pixels,i)=>assert.deepEqual(fs.readFileSync(path.join(out,`frame-${i}.rgba`)),Buffer.from(pixels),`${name} frame ${i}`));
    if(delays){const meta=fs.readFileSync(path.join(out,'metadata.txt'),'utf8').trim().split(/\r?\n/);assert.deepEqual(meta.slice(1).map(Number),delays);}
  }else{
    assert.equal(result.status,1,`${name}: expected clean rejection, got ${result.status}`);
    assert.match(result.stdout,/ERROR:/);
    assert.doesNotMatch(result.stdout,/access violation|range check|overflow|out of memory/i);
  }
  passed++;console.log('PASS '+name);
}
const R=[255,0,0,255],G=[0,255,0,255],B=[0,0,255,255],T=[0,0,0,0];
const rgba=(...px)=>px.flat();
const compositing=make({width:2,height:2,plays:2,frames:[
  {pixels:rgba(R,R,R,R)},
  {w:1,h:1,pixels:[0,0,255,128],blend:1,dispose:2},
  {w:1,h:1,x:1,pixels:G,dispose:1},
  {w:1,h:1,y:1,pixels:[20,40,60,128]},
  {w:1,h:1,y:1,pixels:[100,200,50,128],blend:1},
]});
run('source-over-and-all-disposal-modes',compositing,[
  rgba(R,R,R,R),rgba([127,0,128,255],R,R,R),rgba(R,G,R,R),
  rgba(R,T,[20,40,60,128],R),rgba(R,T,[73,147,53,192],R),
]);
run('hidden-default-and-first-previous',make({width:2,height:1,hiddenDefault:true,frames:[
  {w:1,h:1,x:1,pixels:B,dispose:2}, {w:1,h:1,pixels:G},
]}),[rgba(T,B),rgba(G,T)]);
run('palette-alpha',make({width:2,height:1,palette:[255,0,0,0,255,0],transparency:[255,128],frames:[{pixels:[0,1]}]}),[rgba(R,[0,255,0,128])]);
run('zero-delay-and-default-denominator',make({width:1,height:1,frames:[{pixels:R,num:0,den:0},{pixels:B,num:1,den:0}]}),[R,B],[1000000,10000000]);
run('source-replaces-transparent-rgb',make({width:1,height:1,frames:[{pixels:R},{pixels:[17,29,39,0]}]}),[R,[17,29,39,0]]);
const badCRC=Buffer.from(compositing);badCRC[50]^=1;run('reject-bad-crc',badCRC);
run('reject-truncation',compositing.subarray(0,compositing.length-3));
run('reject-cache-overflow',make({width:4096,height:4096,declared:1024,frames:[{w:1,h:1,pixels:R}]}));
run('reject-bounds',make({width:1,height:1,frames:[{pixels:R},{w:1,h:1,x:1,pixels:B}]}));
run('reject-frame-count',make({width:1,height:1,declared:3,frames:[{pixels:R}]}));
function mutate(bytes,type,fn){
  let result=[bytes.subarray(0,8)],done=false;
  for(let o=8;o<bytes.length;){const n=bytes.readUInt32BE(o),t=bytes.toString('ascii',o+4,o+8),d=Buffer.from(bytes.subarray(o+8,o+8+n));
    if(t===type&&!done){fn(d);done=true;}result.push(chunk(t,d));o+=n+12;
  }return Buffer.concat(result);
}
run('reject-sequence',mutate(compositing,'fdAT',d=>d.writeUInt32BE(999)));
run('reject-disposal',mutate(compositing,'fcTL',d=>d[24]=3));
run('reject-trailing-bytes',Buffer.concat([compositing,Buffer.from('extra')]));


// Generate filtered scanlines from sample values, independently of the Pascal decoder.
const passes=[[0,0,1,1],[0,0,8,8],[4,0,8,8],[0,4,4,8],[2,0,4,4],[0,2,2,4],[1,0,2,2],[0,1,1,2]];
function paeth(a,b,c) {
  const p=a+b-c, d=[Math.abs(p-a),Math.abs(p-b),Math.abs(p-c)];
  return d[0]<=d[1]&&d[0]<=d[2]?a:d[1]<=d[2]?b:c;
}
function encodeSamples(width,height,samples,channels,depth,interlace,filter) {
  const rows=[],bpp=Math.ceil(channels*depth/8);
  for(const [sx,sy,dx,dy] of interlace?passes.slice(1):passes.slice(0,1)) {
    if(sx>=width||sy>=height)continue;
    const pw=Math.ceil((width-sx)/dx),rowSize=Math.ceil(pw*channels*depth/8);
    let previous=Buffer.alloc(rowSize);
    for(let y=sy;y<height;y+=dy) {
      const row=Buffer.alloc(rowSize);let index=0;
      for(let x=sx;x<width;x+=dx)for(let c=0;c<channels;c++,index++) {
        const v=samples[(y*width+x)*channels+c];
        if(depth===16)row.writeUInt16BE(v,index*2);
        else if(depth===8)row[index]=v;
        else row[Math.floor(index*depth/8)]|=v<<(8-depth-index*depth%8);
      }
      const filtered=Buffer.alloc(rowSize+1);filtered[0]=filter;
      for(let i=0;i<rowSize;i++) {
        const a=i>=bpp?row[i-bpp]:0,b=previous[i],c=i>=bpp?previous[i-bpp]:0;
        filtered[i+1]=(row[i]-[0,a,b,Math.floor((a+b)/2),paeth(a,b,c)][filter]+256)&255;
      }
      rows.push(filtered);previous=row;
    }
  }
  return zlib.deflateSync(Buffer.concat(rows));
}
const formats=[[0,1],[0,2],[0,4],[0,8],[0,16],[2,8],[2,16],[3,1],[3,2],[3,4],[3,8],[4,8],[4,16],[6,8],[6,16]];
function sampleFixture(color,depth,width,height,interlace,filter) {
  const channels=({0:1,2:3,3:1,4:2,6:4})[color],max=2**depth-1;
  const samples=Array.from({length:width*height*channels},(_,i)=>(i*7919+Math.floor(i/7)*113+257)% (max+1));
  const palette=color===3?Array.from({length:(max+1)*3},(_,i)=>(i*53+17)&255):null;
  let transparency=null;
  if(color===3)transparency=Array.from({length:max},(_,i)=>(i*71)&255);
  else if(color===0||color===2) {
    transparency=Buffer.alloc(channels*2);
    for(let c=0;c<channels;c++)transparency.writeUInt16BE(samples[c],c*2);
    // The low 16-bit byte matters to tRNS even when the resulting 8-bit color is identical.
    if(depth===16&&width*height>1)for(let c=0;c<channels;c++)samples[channels+c]=samples[c]+1;
  }
  const expected=[];
  for(let i=0;i<width*height;i++) {
    const original=samples.slice(i*channels,(i+1)*channels);
    const v=original.map(s=>depth===16?s>>>8:depth<8?s*255/max:s);
    if(color===3)expected.push(...palette.slice(original[0]*3,original[0]*3+3),transparency[original[0]]??255);
    else {
      let alpha=255;
      if(transparency&&original.every((s,c)=>s===transparency.readUInt16BE(c*2)))alpha=0;
      if(color===0||color===4)expected.push(v[0],v[0],v[0],color===4?v[1]:alpha);
      else expected.push(v[0],v[1],v[2],color===6?v[3]:alpha);
    }
  }
  return {bytes:make({width,height,depth,color,interlace,palette,transparency,
    frames:[{data:encodeSamples(width,height,samples,channels,depth,interlace,filter)}]}),expected};
}
for(const [color,depth] of formats) {
  for(const interlace of [0,1])for(let filter=0;filter<5;filter++) {
    const f=sampleFixture(color,depth,13,11,interlace,filter);
    run(`format-${color}-${depth}-interlace-${interlace}-filter-${filter}`,f.bytes,[f.expected]);
  }
  for(const [width,height] of [[1,1],[1,9],[9,1]]) {
    const f=sampleFixture(color,depth,width,height,1,4);
    run(`adam7-small-${color}-${depth}-${width}x${height}`,f.bytes,[f.expected]);
  }
}
const valid=make({width:1,height:1,frames:[{pixels:R}]});
function replaceChunk(bytes,type,replacements) {
  const result=[signature];
  for(let o=8;o<bytes.length;) {
    const n=bytes.readUInt32BE(o),t=bytes.toString('ascii',o+4,o+8);
    result.push(...(t===type?replacements(bytes.subarray(o+8,o+8+n)):[bytes.subarray(o,o+n+12)]));o+=n+12;
  }
  return Buffer.concat(result);
}
for(const [name,raw] of [
  ['short-scanline',[0,255]],['extra-scanline-byte',[0,...R,42]],['invalid-filter',[5,...R]],
])run('reject-'+name,replaceChunk(valid,'IDAT',()=>[chunk('IDAT',zlib.deflateSync(Buffer.from(raw)))]));
run('reject-truncated-zlib',replaceChunk(valid,'IDAT',d=>[chunk('IDAT',d.subarray(0,d.length-1))]));
run('reject-zlib-checksum',mutate(valid,'IDAT',d=>d[d.length-1]^=1));
run('reject-extra-zlib-stream',replaceChunk(valid,'IDAT',d=>[chunk('IDAT',Buffer.concat([d,d]))]));
run('reject-inflate-bomb',replaceChunk(valid,'IDAT',()=>[chunk('IDAT',zlib.deflateSync(Buffer.alloc(1024*1024)))]));
for(const [color,depth] of [[1,8],[5,8],[7,8],[3,16],[2,4],[4,1],[6,2],[0,3]])
  run(`reject-format-${color}-${depth}`,mutate(valid,'IHDR',d=>{d[8]=depth;d[9]=color;}));
run('reject-interlace',mutate(valid,'IHDR',d=>d[12]=2));
run('reject-compression',mutate(valid,'IHDR',d=>d[10]=1));
run('reject-filter-method',mutate(valid,'IHDR',d=>d[11]=1));
run('reject-missing-palette',mutate(valid,'IHDR',d=>d[9]=3));
run('reject-palette-index',make({width:1,height:1,palette:[1,2,3],frames:[{pixels:[1]}]}));
run('reject-palette-size',make({width:1,height:1,palette:[1,2],frames:[{pixels:[0]}]}));
run('reject-palette-alpha-size',make({width:1,height:1,palette:[1,2,3],transparency:[0,1],frames:[{pixels:[0]}]}));
run('reject-rgba-trns',make({width:1,height:1,transparency:[0,0],frames:[{pixels:R}]}));
run('reject-gray-trns-range',make({width:1,height:1,color:0,depth:8,transparency:[1,0],frames:[{data:zlib.deflateSync(Buffer.from([0,0]))}]}));
run('split-idat',replaceChunk(valid,'IDAT',d=>[chunk('IDAT'),...Array.from(d,b=>chunk('IDAT',Buffer.from([b])))]),[R]);
run('reject-nonconsecutive-idat',replaceChunk(valid,'IDAT',d=>[
  chunk('IDAT',d.subarray(0,2)),chunk('tEXt',Buffer.from('key\0value')),chunk('IDAT',d.subarray(2)),
]));
// Split animation frame data too, maintaining the APNG sequence across chunk boundaries.
const twoFrames=make({width:1,height:1,frames:[{pixels:R},{pixels:B}]});
run('split-fdat',replaceChunk(twoFrames,'fdAT',d=>Array.from(d.subarray(4),(b,i)=>{
  const data=Buffer.alloc(5);data.writeUInt32BE(d.readUInt32BE(0)+i);data[4]=b;return chunk('fdAT',data);
})),[R,B]);
const partialSamples=Array.from({length:5*3*4},(_,i)=>(i*71)&255);
const partialExpected=Buffer.alloc(9*7*4);
for(let y=0;y<3;y++)Buffer.from(partialSamples.slice(y*20,(y+1)*20)).copy(partialExpected,((y+2)*9+3)*4);
run('interlaced-partial-frame',make({width:9,height:7,interlace:1,frames:[
  {data:encodeSamples(9,7,Array(9*7*4).fill(0),4,8,1,2)},
  {w:5,h:3,x:3,y:2,data:encodeSamples(5,3,partialSamples,4,8,1,4)},
]}),[Buffer.alloc(9*7*4),partialExpected]);
run('over-alpha-fast-paths',make({width:3,height:1,frames:[
  {pixels:rgba([12,34,56,0],R,[80,60,40,128])},
  {pixels:rgba([11,22,33,0],[44,55,66,0],B),blend:1},
  {pixels:rgba([17,27,37,128],G,[99,88,77,0]),blend:1},
]}),[rgba([12,34,56,0],R,[80,60,40,128]),rgba(T,R,B),rgba([17,27,37,128],G,B)]);
// Larger, reusable fixture for manual load-time benchmarking.
const largePixels=Array.from({length:512*288*4},(_,i)=>(i*17+Math.floor(i/2048)*31)&255);
run('large-animation',make({width:512,height:288,frames:Array.from({length:12},()=>({pixels:largePixels}))}),
  Array(12).fill(largePixels));
// Deterministic reference compositing with varied multi-row rectangles and frame delays.
let seed=123456;
function random(n){seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed%n;}
const referenceFrames=[],referencePixels=[],referenceDelays=[];
let canvas=Array(17*13*4).fill(0);
for(let frame=0;frame<60;frame++) {
  const w=frame?1+random(17):17,h=frame?1+random(13):13;
  const x=random(18-w),y=random(14-h),blend=random(2),dispose=random(3);
  const pixels=Array.from({length:w*h*4},(_,i)=>i%4===3?[0,1,127,128,254,255][random(6)]:random(256));
  const num=random(17),den=[0,10,100,1000,65535][random(5)];
  referenceFrames.push({w,h,x,y,blend,dispose,num,den,pixels});
  referenceDelays.push(Math.max(1000000,Math.floor(num*1e9/(den||100))));
  const before=canvas.slice();
  for(let py=0;py<h;py++)for(let px=0;px<w;px++) {
    const src=(py*w+px)*4,dst=((py+y)*17+px+x)*4;
    if(blend===0)for(let c=0;c<4;c++)canvas[dst+c]=pixels[src+c];
    else {
      const sa=pixels[src+3],da=canvas[dst+3],alpha=sa*255+da*(255-sa);
      for(let c=0;c<3;c++)canvas[dst+c]=alpha?Math.floor((pixels[src+c]*sa*255+canvas[dst+c]*da*(255-sa)+Math.floor(alpha/2))/alpha):0;
      canvas[dst+3]=Math.floor((alpha+127)/255);
    }
  }
  referencePixels.push(canvas.slice());
  if(dispose===2)canvas=before;
  else if(dispose===1)for(let py=0;py<h;py++)for(let px=0;px<w;px++)canvas.fill(0,((py+y)*17+px+x)*4,((py+y)*17+px+x)*4+4);
}
run('reference-compositing-and-timing',make({width:17,height:13,plays:3,frames:referenceFrames}),referencePixels,referenceDelays);
console.log(`${passed} decoder cases passed.`);
