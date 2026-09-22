import MarkdownIt from 'markdown-it';
import taskLists from 'markdown-it-task-lists';
import texmath from 'markdown-it-texmath';
import DOMPurify from 'dompurify';

const md = new MarkdownIt({html: true, linkify: true, typographer: false}).use(taskLists);
for (const rule of ['th_open','td_open']) md.renderer.rules[rule] = (tokens,index,options,env,renderer) => {
  const align=tokens[index].attrGet('style');
  if (align && /^text-align:(left|right|center)$/.test(align)) tokens[index].attrJoin('class','align-'+align.split(':')[1]);
  return renderer.renderToken(tokens,index,options);
};
let math = [], diagrams = [];
// The established texmath tokenizer finds TeX. Rendering remains lazy: no KaTeX
// code is in the core bundle or loaded for documents without mathematics.
md.use(texmath, {delimiters: ['dollars', 'brackets'], engine: {renderToString(source, options) {
  const id = math.push({source, display: options.displayMode}) - 1;
  return `<span data-orkhon-math="${id}"></span>`;
}}});
const fence = md.renderer.rules.fence;
md.renderer.rules.fence = (tokens, index, options, env, renderer) => {
  if (tokens[index].info.trim().toLowerCase() !== 'mermaid') return fence(tokens, index, options, env, renderer);
  const id = diagrams.push(tokens[index].content) - 1;
  return `<figure data-orkhon-diagram="${id}"></figure>`;
};
const loads = new Map(), diagramCache = new Map();
let revision = 0, diagramSequence = 0, currentDocument = null;
function script(name) {
  if (!loads.has(name)) loads.set(name, new Promise((resolve, reject) => {
    const element = document.createElement('script'); element.src = name;
    element.onload = resolve; element.onerror = () => {loads.delete(name); element.remove(); reject(new Error(`Unable to load ${name}`));};
    document.head.append(element);
  }));
  return loads.get(name);
}
function css(name) {
  if (document.querySelector(`link[data-optional="${name}"]`)) return;
  const element = document.createElement('link'); element.rel = 'stylesheet'; element.href = name; element.dataset.optional = name; document.head.append(element);
}
function resourceURL(value, base) {
  try {
    if (!base || /^(?:[a-z][a-z0-9+.-]*:|#|\/\/)/i.test(value)) return value;
    return new URL(value, base).href;
  } catch {return '';}
}
function showError(element, source, message) {
  const details = document.createElement('details'); details.className = 'render-error'; details.open = true;
  const label = document.createElement('summary'); label.textContent = message;
  const code = document.createElement('pre'); code.textContent = source; details.append(label, code); element.replaceChildren(details);
}
async function render(source, theme, base, documentID, assetRevision = "0") {
  const version = ++revision;
  document.documentElement.style.colorScheme = theme.dark ? 'dark' : 'light';
  for (const key of ['background','foreground','muted','accent','panel','line']) document.documentElement.style.setProperty(`--${key}`, theme[key]);
  math = []; diagrams = [];
  const rendered = md.render(source), formulas = math, charts = diagrams;
  const fragment = DOMPurify.sanitize(rendered, {RETURN_DOM_FRAGMENT: true, ADD_TAGS: ['eq','eqn'],
    FORBID_TAGS: ['style','iframe','object','embed','form','base','script'], FORBID_ATTR: ['style','srcset'],
    ALLOW_DATA_ATTR: true, ALLOW_UNKNOWN_PROTOCOLS: false});
  for (const element of fragment.querySelectorAll('[src],a[href]')) {
    const attr = element.hasAttribute('src') ? 'src' : 'href';
    element.setAttribute(attr, resourceURL(element.getAttribute(attr), base));
    if (element.tagName === 'IMG') {
      // A filesystem batch invalidates document assets even if Markdown is unchanged.
      // Preserve anchors, existing query parameters, and immutable renderer resources.
      try {
        const url = new URL(element.getAttribute('src'));
        if (['orkhon-document:', 'orkhon-remote:'].includes(url.protocol)) {
          url.searchParams.set('orkhon-revision', assetRevision); element.src = url.href;
        }
      } catch {}
      element.loading = 'lazy'; element.decoding = 'async';
    }
  }
  const article = document.querySelector('article'), position = documentID === currentDocument ? window.scrollY : 0;
  currentDocument = documentID; article.replaceChildren(fragment); window.scrollTo(0,position);
  // Apply independent optional renderers in parallel. Stale work never replaces
  // the current document; diagram rendering itself is serialized by Mermaid.
  const mathWork = formulas.length ? (async () => {
    css('katex.min.css'); await script('katex.min.js'); if (version !== revision) return;
    for (const element of article.querySelectorAll('[data-orkhon-math]')) {
      const value = formulas[Number(element.dataset.orkhonMath)]; if (!value) continue;
      try {window.katex.render(value.source, element, {displayMode:value.display, throwOnError:false, trust:false, strict:'warn', maxExpand:1000, maxSize:20, output:'htmlAndMathml'});}
      catch {showError(element,value.source,'Formula could not be rendered');}
    }
  })() : Promise.resolve();
  const diagramWork = charts.length ? (async () => {
    await script('mermaid.min.js'); if (version !== revision) return;
    window.mermaid.initialize({startOnLoad:false, securityLevel:'strict', theme:theme.dark ? 'dark':'default', suppressErrorRendering:true,
      maxTextSize:50000, maxEdges:500, fontFamily:'-apple-system, BlinkMacSystemFont, sans-serif',
      flowchart:{htmlLabels:false}, themeVariables:{background:theme.background, primaryColor:theme.panel, primaryTextColor:theme.foreground}});
    for (const element of article.querySelectorAll('[data-orkhon-diagram]')) {
      if (version !== revision) return;
      const value = charts[Number(element.dataset.orkhonDiagram)]; if (value === undefined) continue;
      if (value.length > 50000) {showError(element,value,'Diagram exceeds the 50 KB preview limit');continue;}
      const key = `${theme.dark}:${theme.background}:${value}`;
      try {
        let svg = diagramCache.get(key);
        if (!svg) {
          const result = await window.mermaid.render(`diagram-${++diagramSequence}`, value);
          svg = result.svg;
          if (svg.length < 250000) {diagramCache.set(key, svg); while (diagramCache.size > 16) diagramCache.delete(diagramCache.keys().next().value);}
        }
        if (version !== revision) return;
        element.innerHTML = DOMPurify.sanitize(svg, {USE_PROFILES:{svg:true,svgFilters:true}, ADD_TAGS:['foreignObject'], FORBID_TAGS:['script'], FORBID_ATTR:['onload']});
        element.setAttribute('aria-label','Mermaid diagram');
      } catch {if (version === revision) showError(element,value,'Check this Mermaid diagram’s syntax');}
    }
  })() : Promise.resolve();
  const outcomes = await Promise.allSettled([mathWork, diagramWork]);
  if (version === revision) {
    if (outcomes[0].status === 'rejected') for (const element of article.querySelectorAll('[data-orkhon-math]')) {
      const value=formulas[Number(element.dataset.orkhonMath)]; if(value) showError(element,value.source,'Formula renderer could not be loaded');
    }
    if (outcomes[1].status === 'rejected') for (const element of article.querySelectorAll('[data-orkhon-diagram]')) {
      const value=charts[Number(element.dataset.orkhonDiagram)]; if(value !== undefined) showError(element,value,'Diagram renderer could not be loaded');
    }
  }
  if (version === revision) {document.documentElement.dataset.rendered = String(version); window.scrollTo(0,position);}
  return {version, current:version === revision, math:formulas.length, diagrams:charts.length};
}
window.orkhon = {render};
