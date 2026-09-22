import {createRequire} from 'node:module';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {fileURLToPath} from 'node:url';
const here = path.dirname(fileURLToPath(import.meta.url)), root = path.resolve(here,'../..');
const modules = process.env.ORKHON_MARKDOWN_NODE_MODULES || path.join(here,'node_modules');
const {build} = createRequire(path.join(modules,'../package.json'))('esbuild');
const destination = path.join(root,'Resources/MarkdownPreview');
await build({entryPoints:[path.join(here,'entry.js')], outfile:path.join(destination,'core.min.js'), bundle:true, minify:true, format:'iife', target:'safari16', legalComments:'linked', nodePaths:[modules], alias:{katex:path.join(here,'katex-stub.js')}});
for (const [source,target] of [['katex/dist/katex.min.js','katex.min.js'],['katex/dist/katex.min.css','katex.min.css'],['mermaid/dist/mermaid.min.js','mermaid.min.js']]) fs.copyFileSync(path.join(modules,source),path.join(destination,target));
const fonts = path.join(destination,'fonts');fs.mkdirSync(fonts,{recursive:true});
for (const name of fs.readdirSync(path.join(modules,'katex/dist/fonts')).filter(v=>v.endsWith('.woff2'))) fs.copyFileSync(path.join(modules,'katex/dist/fonts',name),path.join(fonts,name));
// WebKit on every supported macOS understands WOFF2. Omit legacy TTF/WOFF.
const css = path.join(destination,'katex.min.css');fs.writeFileSync(css,fs.readFileSync(css,'utf8').replace(/,url\([^)]*\.woff\) format\("woff"\),url\([^)]*\.ttf\) format\("truetype"\)/g,''));
const licenses=path.join(root,'Vendor/MarkdownPreview/Licenses');fs.mkdirSync(licenses,{recursive:true});
function collect(directory) {
 for (const entry of fs.readdirSync(directory,{withFileTypes:true})) {
  if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
  const folder=path.join(directory,entry.name);
  if (entry.name.startsWith('@')) {collect(folder);continue;}
  if (!fs.existsSync(path.join(folder,'package.json'))) continue;
  const metadata=JSON.parse(fs.readFileSync(path.join(folder,'package.json'),'utf8'));
  for (const file of fs.readdirSync(folder).filter(v=>/^(license|licence|copying|notice)(\.|$)/i.test(v))) {
   if(fs.statSync(path.join(folder,file)).isFile()) fs.copyFileSync(path.join(folder,file),path.join(licenses,`${metadata.name.replaceAll('/','_')}-${metadata.version}-${file}`));
  }
  if (fs.existsSync(path.join(folder,'node_modules'))) collect(path.join(folder,'node_modules'));
 }
}
collect(modules);
const hashes={};function hashFiles(directory){for(const entry of fs.readdirSync(directory,{withFileTypes:true})){const file=path.join(directory,entry.name);if(entry.isDirectory())hashFiles(file);else hashes[path.relative(destination,file)]=crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');}}
hashFiles(destination);fs.writeFileSync(path.join(root,'Vendor/MarkdownPreview/SHA256.json'),JSON.stringify(hashes,null,2)+'\n');
