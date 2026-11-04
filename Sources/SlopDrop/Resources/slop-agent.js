// SlopDrop renderer agent.
//
// Injected into Slack's web client at document start. It owns four things:
//   1. reading a message's real metadata out of React's fiber tree,
//   2. matching that metadata against rules pushed from the native app,
//   3. applying a named style by setting data-sd-* attributes on the row,
//   4. reporting what it sees (apps, "Sent using" signatures) so the app can
//      suggest what to hide.
//
// Styles are pure CSS. The agent never inserts, removes or reorders Slack's
// nodes, so React reconciliation can't fight it; it only adds attributes to
// the virtual-list row Slack already renders, and to <html> for theme/pick.
//
// Adding a style = add an entry to STYLES below. The app reads the registry at
// runtime, so nothing on the Swift side has to change.
(() => {
  const VERSION = 25;
  const previous = window.__slop;
  if ((previous?.version ?? 0) >= VERSION) return;

  // Retire an older agent. v4 and earlier have no dispose(): emptying their
  // rules makes them clear only their own data-slop-* attributes, which this
  // version no longer uses.
  if (previous) {
    try {
      if (typeof previous.dispose === 'function') previous.dispose();
      else {
        previous.setRules?.([]);
        previous.configure?.({ pick: false });
      }
    } catch {}
    document.getElementById('slop-styles')?.remove();
    document.documentElement.removeAttribute('data-slop-pick');
  }

  const MSG = '[data-qa="message_container"]';
  const ROW = '[data-qa="virtual-list-item"]';
  const RIGHT = '.c-message_kit__gutter__right';
  const BODY = ':is(.c-message__body, .c-message_kit__blocks, .c-files_container, .c-message_kit__attachments, .c-message_attachment, [data-qa="message_attachments"])';
  const A = {
    style: 'data-sd-style',
    rule: 'data-sd-rule',
    chip: 'data-sd-chip', // id of a generated rule that sets --sd-chip-text
    open: 'data-sd-open',
    hot: 'data-sd-hot', // pointer is over something that toggles the fold
    lift: 'data-sd-lift', // px to lower a folded chip onto the text baseline
    fit: 'data-sd-fit', // px height of a folded message: its first line, chip included
    faces: 'data-sd-faces', // slop reply-bar faces as "<position>-<dim|gray>" tokens
    thread: 'data-sd-thread', // dim|gray: mute the reply count, because every replier is slop
    cut: 'data-sd-cut', // card: "fit" (short), "open" (shown in full), or a generated cut id
  };
  // Fold geometry. The chip is CHIP_LINE tall. A folded message shows exactly
  // its first line: the line box, grown only by taller things on it, so plain
  // lines all fold to the same height. MIN_FIT is a floor for odd content.
  const CHIP_LINE = 19;
  const MIN_FIT = CHIP_LINE + 3;
  const MAX_FIT = 44;
  const MAX_LIFT = MAX_FIT - CHIP_LINE - 2;
  const S = (id) => `[${A.style}="${id}"]`;
  const ROOT = document.documentElement;
  // The timestamp only exists in a row's header, so it doubles as "has header".
  const STAMP = `${RIGHT} > .c-timestamp`;
  // The first body part of a message: where its first line of content starts,
  // on header rows and follow-up rows alike.
  const FIRST_BODY = `${RIGHT} > ${BODY}:not(${BODY} ~ ${BODY})`;
  const NO_BODY = `:not(:has(${RIGHT} > ${BODY}))`;
  const LAST_BODY = `${RIGHT} > ${BODY}:not(:has(~ ${BODY}))`;
  // Muted messages that keep their body on screen sit in a card, like Slack's
  // own shared messages, cut off after about five lines with "Show more".
  // The card is drawn on the body parts themselves: the top edge on the first,
  // the sides on all, the bottom on the last one showing. Frost is a card of
  // glass already; Fold and Hide show no body to card.
  const CARD_HOSTS = ['dim', 'monochrome', 'outline'];
  const CARDED = `:is(${CARD_HOSTS.map(S).join(', ')})`;
  const CARD_LINE = 22;
  const CARD_LINES = 5;
  // Never cut off less than this; "Show more" for one line is a cheat.
  const CARD_MIN_HIDDEN = 2 * CARD_LINE;
  const CARD_PAD = 12;
  // The link copies Slack's own (.c-rich_text_expand_button): Lato 13px bold
  // on a 20px line, 4px under the text, in Slack's link colour token, followed
  // by Slack's 20px chevron.
  const SLACK_LINK = '--dt_color-content-hgl-1';
  const LINK_LINE = 20;
  const LINK_GAP = 4;
  const LINK_ROOM = LINK_GAP + LINK_LINE + 10;
  const LINK_CHEVRON = 20;
  const LINK_FONT = '700 13px Slack-Lato, Slack-Fractions, appleLogo, sans-serif';
  const CARD_BOTTOM = `
    border-bottom: 1px solid var(--sd-card-edge);
    border-end-start-radius: 12px; border-end-end-radius: 12px;
    padding-bottom: 10px !important; margin-bottom: 4px !important;
  `;
  const LINK = `
    position: absolute; z-index: 1; pointer-events: none; white-space: nowrap;
    font: ${LINK_FONT}; line-height: ${LINK_LINE}px; color: var(${SLACK_LINK}, var(--sd-link));
    padding-right: ${LINK_CHEVRON}px; background: no-repeat right center / ${LINK_CHEVRON}px ${LINK_CHEVRON}px;
  `;
  // Slack's chevron path. Slack masks it with the link colour; a pseudo-element
  // can't mask only part of itself, so the colour is baked into the image.
  const chevron = (color, up) => `url("data:image/svg+xml,${encodeURIComponent(
    `<svg xmlns='http://www.w3.org/2000/svg' width='20' height='20' viewBox='0 0 20 20'><path${up ? " transform='rotate(180 10 10)'" : ''} fill='${color}' fill-rule='evenodd' clip-rule='evenodd' d='M5.72 7.47a.75.75 0 0 1 1.06 0L10 10.69l3.22-3.22a.75.75 0 1 1 1.06 1.06l-3.75 3.75a.75.75 0 0 1-1.06 0L5.72 8.53a.75.75 0 0 1 0-1.06'/></svg>`,
  )}")`;
  // Slack's link colour as last read, so the chevron is rebuilt when it changes.
  let linkColor = '';
  function slackLinkColor() {
    const value = getComputedStyle(document.body || ROOT).getPropertyValue(SLACK_LINK).trim();
    return value || (ROOT.getAttribute('data-sd-theme') === 'dark' ? 'rgb(43,165,206)' : 'rgb(18,100,163)');
  }
  // Dim and Grayscale mute the message itself, not its thread preview. A face
  // in the preview is muted only when that replier is slop too, in the style
  // of their own rule, under every message, muted or not. data-sd-faces lists
  // them as "<position>-<kind>" tokens, e.g. "2-dim 3-gray". The reply count
  // is muted only when every replier is slop (data-sd-thread).
  const REPLY_BAR = '.c-message__reply_bar';
  const REPLY_FACE = '.c-message__reply_bar_avatar';
  const THREAD_TEXT = `${RIGHT} > ${REPLY_BAR} > :not(${REPLY_FACE})`;
  const MUTED_PARTS = `:is(.c-message_kit__gutter__left, ${RIGHT} > :not(${REPLY_BAR}))`;
  const MAX_FACES = 6;
  const slopFaces = (kind, state = '') => Array.from({ length: MAX_FACES }, (_, i) =>
    `[${A.faces}~="${i + 1}-${kind}"]${state} ${REPLY_BAR} > :nth-child(${i + 1})`).join(', ');

  // One source for each mute, shared by a message and a replier's face.
  const MUTE = {
    dim: 'opacity: .2;',
    gray: 'filter: grayscale(1) contrast(.85); opacity: .2;',
    restore: 'filter: none; opacity: 1;',
    transition: 'transition: filter .18s ease-out, opacity .18s ease-out;',
  };

  // ------------------------------------------------------------------ styles
  // id    – stored in rules, so it must stay stable
  // title – shown in the app
  // blurb – one line of help
  // css   – keyed off [data-sd-style="<id>"] on the message row
  //
  // Chips float at the start of a message's first line. They take real space
  // (text wraps around them), sit in the same place whether or not the row
  // has a header, and stay clear of Slack's hover toolbar on the right.
  const STYLES = {
    monochrome: {
      title: 'Grayscale',
      blurb: 'Drains colour so it reads as background noise, in a card. Long ones end in Show more. Faces of people who replied stay lit.',
      css: `
        ${S('monochrome')} ${MUTED_PARTS} { ${MUTE.gray} ${MUTE.transition} }
        ${S('monochrome')}:hover ${MUTED_PARTS} { ${MUTE.restore} }
      `,
    },
    accordion: {
      title: 'Fold',
      blurb: 'Keeps the sender and the first line. Click the message to unfold or fold it.',
      css: `
        ${S('accordion')}:not([${A.open}]) { cursor: pointer; }
        ${S('accordion')}:not([${A.open}]) ${RIGHT} > ${BODY} {
          max-height: ${MIN_FIT}px; overflow: hidden; pointer-events: none;
        }
        ${S('accordion')}:not([${A.open}]) ${RIGHT} > ${BODY} ~ ${BODY},
        ${S('accordion')}:not([${A.open}]) .c-message_kit__reaction_bar { display: none !important; }
        ${S('accordion')}:is([${A.hot}="row"], [${A.hot}="chip"]) { cursor: pointer; }
        ${S('accordion')}[${A.open}] ${RIGHT} > ${BODY} { animation: sd-unfold .2s ease-out; }
        @keyframes sd-unfold { from { opacity: 0; transform: translateY(-2px); } }
      `,
    },
    blur: {
      title: 'Frost',
      blurb: 'Frosted glass over the message body. Hover to read.',
      css: `
        ${S('blur')}::after {
          content: ''; position: absolute; z-index: 2; pointer-events: none;
          left: 56px; right: 12px; top: 4px; bottom: 4px; border-radius: 10px;
          background: linear-gradient(180deg, var(--sd-glass-top), var(--sd-glass-bottom));
          -webkit-backdrop-filter: blur(9px) saturate(180%);
                  backdrop-filter: blur(9px) saturate(180%);
          box-shadow: inset 0 0 0 0.5px var(--sd-edge), inset 0 1px 0 var(--sd-highlight), 0 1px 2px var(--sd-shadow);
          transition: opacity .22s ease-out, backdrop-filter .22s ease-out, -webkit-backdrop-filter .22s ease-out;
        }
        ${S('blur')}:has(${STAMP})::after { top: 29px; }
        ${S('blur')}::before {
          content: var(--sd-chip-text, ''); position: absolute; z-index: 3; pointer-events: none;
          left: 66px; top: calc(4px + clamp(2px, (100% - 8px - 20px) / 2, 10px));
          transition: opacity .18s ease-out;
        }
        ${S('blur')}:has(${STAMP})::before { top: calc(29px + clamp(2px, (100% - 33px - 20px) / 2, 10px)); }
        ${S('blur')}:hover::after {
          opacity: 0; -webkit-backdrop-filter: blur(0) saturate(100%); backdrop-filter: blur(0) saturate(100%);
          transition-delay: 80ms;
        }
        ${S('blur')}:hover::before { opacity: 0; transition-delay: 80ms; }
      `,
    },
    dim: {
      title: 'Dim',
      blurb: 'Fades the message, in a card, until you hover. Long ones end in Show more. Faces of people who replied stay lit.',
      css: `
        ${S('dim')} ${MUTED_PARTS} { ${MUTE.dim} ${MUTE.transition} }
        ${S('dim')}:hover ${MUTED_PARTS} { ${MUTE.restore} }
      `,
    },
    outline: {
      title: 'Tag',
      blurb: 'Labels the message and puts it in a card. Long ones end in Show more.',
      css: `
        ${S('outline')} { box-shadow: inset 2px 0 0 var(--sd-accent); }
        ${S('outline')} ${FIRST_BODY}::before,
        ${S('outline')}${NO_BODY} ${RIGHT}::after { color: var(--sd-accent-ink); background: var(--sd-accent-fill); }
      `,
    },
    hide: {
      title: 'Hide',
      blurb: 'Removes the message from the timeline.',
      css: `${S('hide')} { display: none !important; }`,
    },
  };

  const CHIP = `
    font: 500 11px/19px -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    letter-spacing: .1px; white-space: nowrap; text-decoration: none;
    padding: 0 8px; border-radius: 999px; pointer-events: none;
    color: var(--sd-ink); background: var(--sd-chip);
    box-shadow: inset 0 0 0 0.5px var(--sd-edge);
    transition: background .15s ease-out, color .15s ease-out, box-shadow .15s ease-out;
  `;
  const CHIP_HOSTS = ['accordion', 'outline'];

  function styleSheet() {
    linkColor = slackLinkColor();
    const lead = CHIP_HOSTS.map((id) => `${S(id)} ${FIRST_BODY}::before`).join(', ');
    // A message with no recognisable body still gets a chip, on its own line.
    const bare = CHIP_HOSTS.map((id) => `${S(id)}${NO_BODY} ${RIGHT}::after`).join(', ');
    const hot = `${S('accordion')}[${A.hot}] ${FIRST_BODY}::before, ${S('accordion')}[${A.hot}]${NO_BODY} ${RIGHT}::after`;
    return `
      :root {
        --sd-glass-top: rgba(255,255,255,.46); --sd-glass-bottom: rgba(250,250,252,.3);
        --sd-edge: rgba(0,0,0,.07); --sd-edge-strong: rgba(0,0,0,.16); --sd-highlight: rgba(255,255,255,.85);
        --sd-shadow: rgba(0,0,0,.04); --sd-ink: rgba(29,28,29,.62); --sd-ink-strong: rgba(29,28,29,.9);
        --sd-chip: rgba(29,28,29,.05); --sd-chip-hover: rgba(29,28,29,.1);
        --sd-accent: rgba(124,92,255,.7); --sd-accent-ink: rgb(98,70,214); --sd-accent-fill: rgba(124,92,255,.1);
        --sd-pick: rgba(124,92,255,.9); --sd-pick-fill: rgba(124,92,255,.07); --sd-chip-solid: rgba(255,255,255,.9);
        --sd-card-edge: rgba(29,28,29,.13); --sd-link: rgb(18,100,163);
        --sd-more: ${chevron(linkColor, false)}; --sd-less: ${chevron(linkColor, true)};
      }
      :root[data-sd-theme="dark"] {
        --sd-glass-top: rgba(44,46,52,.5); --sd-glass-bottom: rgba(30,32,36,.34);
        --sd-edge: rgba(255,255,255,.1); --sd-edge-strong: rgba(255,255,255,.22); --sd-highlight: rgba(255,255,255,.07);
        --sd-shadow: rgba(0,0,0,.2); --sd-ink: rgba(236,236,240,.7); --sd-ink-strong: rgba(246,246,250,.95);
        --sd-chip: rgba(255,255,255,.07); --sd-chip-hover: rgba(255,255,255,.14);
        --sd-accent: rgba(160,140,255,.75); --sd-accent-ink: rgb(190,176,255); --sd-accent-fill: rgba(160,140,255,.16);
        --sd-chip-solid: rgba(48,50,56,.92);
        --sd-card-edge: rgba(121,124,129,.3); --sd-link: rgb(43,165,206);
      }
      /* The card, drawn on Slack's own body parts (see CARD_HOSTS). */
      ${CARDED} ${RIGHT} > ${BODY} {
        border-inline: 1px solid var(--sd-card-edge); box-sizing: content-box;
        padding-inline: ${CARD_PAD}px !important; padding-block: 0 !important;
        margin-block: 0 !important; max-width: none !important;
      }
      ${CARDED} ${RIGHT} > ${BODY} ~ ${BODY} { padding-top: 6px !important; }
      ${CARDED} ${FIRST_BODY} {
        border-top: 1px solid var(--sd-card-edge);
        border-start-start-radius: 12px; border-start-end-radius: 12px;
        padding-top: 10px !important; margin-top: 4px !important;
      }
      ${CARDED} ${LAST_BODY} { ${CARD_BOTTOM} }
      ${CARDED}[${A.cut}="open"] ${LAST_BODY} { position: relative; padding-bottom: ${LINK_ROOM}px !important; }
      ${CARDED}[${A.cut}="open"] ${LAST_BODY}::after {
        ${LINK} content: 'Show less'; left: ${CARD_PAD}px; bottom: 10px; background-image: var(--sd-less);
      }
      ${CARDED}[${A.hot}="more"] ${RIGHT} > ${BODY} { cursor: pointer; }
      ${CARDED}[${A.hot}="more"] ${RIGHT} > ${BODY}::after { text-decoration: underline; }
      /* A collapsed card's link is the column's own ::after, outside the cut
         (see cutId), so it fades with the message explicitly. */
      ${S('dim')}[${A.cut}] ${RIGHT}::after { ${MUTE.dim} ${MUTE.transition} }
      ${S('monochrome')}[${A.cut}] ${RIGHT}::after { ${MUTE.gray} ${MUTE.transition} }
      ${CARDED}[${A.cut}]:hover ${RIGHT}::after { ${MUTE.restore} }
      ${CARDED}[${A.hot}="more"] ${RIGHT}::after { text-decoration: underline; }
      ${lead}, ${bare}, ${S('blur')}::before { ${CHIP} }
      ${lead} { content: var(--sd-chip-text, ''); display: block; width: fit-content; margin: 2px 0 6px; }
      /* Folded, the chip leads the one visible line; the line wraps around it.
         Open (or tagged), it sits on its own line in the same spot, because
         Slack's rich-text blocks would otherwise squeeze into a narrow column
         beside a float for their full height. */
      ${S('accordion')}:not([${A.open}]) ${FIRST_BODY}::before { float: left; margin: 1px 8px 0 0; }
      ${bare} { content: var(--sd-chip-text, ''); display: inline-block; margin-top: 2px; }
      ${hot} { background: var(--sd-chip-hover); color: var(--sd-ink-strong); box-shadow: inset 0 0 0 0.5px var(--sd-edge-strong); }
      ${Array.from({ length: MAX_LIFT + 1 }, (_, n) => `${S('accordion')}:not([${A.open}])[${A.lift}="${n}"] ${FIRST_BODY}::before { margin-top: ${n}px; }`).join('\n')}
      ${Array.from({ length: MAX_FIT - MIN_FIT + 1 }, (_, i) => `${S('accordion')}:not([${A.open}])[${A.fit}="${MIN_FIT + i}"] ${RIGHT} > ${BODY} { max-height: ${MIN_FIT + i}px; }`).join('\n')}
      ${S('blur')}::before { background: var(--sd-chip-solid); }
      ${slopFaces('dim')} { ${MUTE.dim} ${MUTE.transition} }
      ${slopFaces('gray')} { ${MUTE.gray} ${MUTE.transition} }
      ${slopFaces('dim', ':hover')}, ${slopFaces('gray', ':hover')} { ${MUTE.restore} }
      [${A.thread}="dim"] ${THREAD_TEXT} { ${MUTE.dim} ${MUTE.transition} }
      [${A.thread}="gray"] ${THREAD_TEXT} { ${MUTE.gray} ${MUTE.transition} }
      [${A.thread}]:hover ${THREAD_TEXT} { ${MUTE.restore} }
      ${Object.values(STYLES).map((s) => s.css).join('\n')}
      @media (prefers-reduced-transparency: reduce) {
        ${S('blur')}::after { -webkit-backdrop-filter: none; backdrop-filter: none; background: var(--sd-chip-solid); }
      }
      @media (prefers-reduced-motion: reduce) {
        ${S('accordion')}[${A.open}] ${RIGHT} > ${BODY} { animation: none; }
      }
      :root[data-sd-pick="on"] ${MSG} { cursor: crosshair !important; }
      :root[data-sd-pick="on"] ${MSG}:hover {
        outline: 2px solid var(--sd-pick); outline-offset: -2px; border-radius: 8px; background: var(--sd-pick-fill);
      }
    `;
  }

  function ensureStyles() {
    let el = document.getElementById('sd-styles');
    if (!el) {
      el = document.createElement('style');
      el.id = 'sd-styles';
      (document.head || ROOT).appendChild(el);
    }
    const css = styleSheet();
    if (el.textContent !== css) el.textContent = css;
  }

  // Chip text lives in CSS custom properties, so a pseudo-element anywhere in
  // the row can show it without SlopDrop touching Slack's own nodes.
  const chipIds = new Map();
  function chipId(text) {
    let id = chipIds.get(text);
    if (id) return id;
    id = String(chipIds.size + 1);
    chipIds.set(text, id);
    let el = document.getElementById('sd-chips');
    if (!el) {
      el = document.createElement('style');
      el.id = 'sd-chips';
      (document.head || ROOT).appendChild(el);
    }
    el.textContent = [...chipIds].map(([t, i]) => `[${A.chip}="${i}"] { --sd-chip-text: ${JSON.stringify(t)}; }`).join('\n');
    return id;
  }

  // Slack has no root-level theme variable, so read the ink colour it renders.
  function detectTheme() {
    const probe = document.querySelector('[data-qa="message-text"], .c-message__sender, .p-channel_sidebar__name');
    if (!probe) return;
    const rgb = (getComputedStyle(probe).color.match(/[\d.]+/g) || []).map(Number);
    if (rgb.length < 3) return;
    const luminance = (0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]) / 255;
    const theme = luminance > 0.5 ? 'dark' : 'light';
    if (ROOT.getAttribute('data-sd-theme') !== theme) ROOT.setAttribute('data-sd-theme', theme);
    if (slackLinkColor() !== linkColor) ensureStyles();
  }

  // ------------------------------------------------------------ slack state
  let fiberKey = null;

  function fiberOf(el) {
    if (!fiberKey || !el[fiberKey]) {
      fiberKey = Object.keys(el).find((k) => k.startsWith('__reactFiber$')) || fiberKey;
    }
    return fiberKey ? el[fiberKey] : null;
  }

  function messageFromFiber(el) {
    let f = fiberOf(el);
    for (let depth = 0; f && depth < 40; depth++) {
      const props = f.memoizedProps;
      if (props && typeof props === 'object' && typeof props.msg?.ts === 'string') return props.msg;
      f = f.return;
    }
    return null;
  }

  let store = null;
  function slackStore() {
    if (store) return store;
    const start = document.querySelector(MSG) || document.querySelector('[data-qa="channel_sidebar"]') ||
      document.querySelector('[data-qa]');
    let f = start && fiberOf(start);
    for (let depth = 0; f && depth < 600; depth++) {
      const candidate = f.memoizedProps?.store || f.memoizedProps?.value?.store;
      if (candidate && typeof candidate.getState === 'function') return (store = candidate);
      f = f.return;
    }
    return null;
  }

  // Installed apps, keyed so a "Sent using <@U…>" or "Sent using Claude"
  // footer resolves to the app that posted it.
  let appIndex = { byId: new Map(), byBotUser: new Map(), byName: new Map(), at: 0 };
  /// Bot user ids and bot ids (B…) → app id (possibly empty), learned from
  /// bot messages seen.
  const knownBots = new Map();
  function apps() {
    if (Date.now() - appIndex.at < 30000 && appIndex.byId.size) return appIndex;
    const state = slackStore()?.getState?.();
    const raw = state?.apps;
    if (!raw || typeof raw !== 'object') return appIndex;
    const byId = new Map();
    const byBotUser = new Map();
    const byName = new Map();
    for (const a of Object.values(raw)) {
      if (!a || !a.id || !a.name) continue;
      const botUserId = a.bot_user?.id || a.app_user?.id || '';
      const entry = {
        id: a.id,
        name: a.name,
        desc: String(a.desc || '').slice(0, 240),
        developer: a.developer_name || '',
        icon: a.icons?.image_72 || a.icons?.image_48 || '',
        botUserId,
        ai: !!a.is_ai_app,
        agent: !!a.is_agent_app,
      };
      byId.set(a.id, entry);
      if (botUserId) byBotUser.set(botUserId, entry);
      const key = a.name.toLowerCase();
      if (!byName.has(key)) byName.set(key, entry);
    }
    appIndex = { byId, byBotUser, byName, at: Date.now() };
    return appIndex;
  }

  // ------------------------------------------------------------- signatures
  // Tools that post on someone's behalf leave a footer: "*Sent using* Claude",
  // "_Sent with <@U0BUGMB8ML2>_". Context blocks are trusted; in plain text the
  // phrase has to be emphasised or on its own final line, so prose like "this
  // is sent with leading zeros" never matches.
  const SIGNATURE = /(?:^|\n|\s)([*_]{0,2})\s*(?:sent|posted|written|drafted|generated|replied)\s+(?:using|with|via|from|by)\s*\1\s*(.+?)\s*$/i;

  function cleanName(raw) {
    let name = String(raw || '').trim();
    const mention = name.match(/^<@([UW][A-Z0-9]+)(?:\|([^>]+))?>/);
    if (mention) {
      const app = apps().byBotUser.get(mention[1]);
      return { name: app?.name || mention[2] || '', appId: app?.id || '' };
    }
    name = name.replace(/^<[^|>]+\|([^>]+)>/, '$1').replace(/^<([^>]+)>/, '$1');
    name = name.replace(/[*_~`]+/g, '').replace(/[.!:;,)\]]+$/, '').replace(/^@/, '').trim();
    if (!name || name.length > 40 || name.split(/\s+/).length > 5) return null;
    return { name, appId: apps().byName.get(name.toLowerCase())?.id || '' };
  }

  function signatureOf(m) {
    for (const block of m.blocks || []) {
      if (block?.type !== 'context') continue;
      for (const e of block.elements || []) {
        const hit = typeof e?.text === 'string' && e.text.match(SIGNATURE);
        if (hit) return cleanName(hit[2]);
      }
    }
    const text = String(m.text || '');
    const lastLine = text.split('\n').pop();
    const hit = lastLine.match(SIGNATURE);
    if (!hit) return null;
    const emphasised = hit[1].length > 0;
    const ownLine = text.includes('\n') && new RegExp('^\\s*[*_]{0,2}\\s*(sent|posted|written|drafted|generated|replied)\\b', 'i').test(lastLine);
    return emphasised || ownLine ? cleanName(hit[2]) : null;
  }

  // ---------------------------------------------------------------- metadata
  // A message can carry someone else's message: a shared message, or a link
  // preview of another post. Its sender, "APP" badge and text belong to that
  // post, so they never describe the message around it.
  const ATTACHED = '.c-message_kit__attachments, .c-message_attachment, [data-qa="message_attachments"]';
  const APP_BADGE = '[data-qa="message_sender_app_badge"]';

  function own(el, selector) {
    for (const node of el?.querySelectorAll(selector) || []) {
      const attachment = node.closest(ATTACHED);
      if (!attachment || !el.contains(attachment)) return node;
    }
    return null;
  }

  function messageFromDOM(el) {
    const sender = own(el, '[data-message-sender]');
    return {
      ts: el.getAttribute('data-msg-ts') || '',
      channel: el.getAttribute('data-msg-channel-id') || '',
      user: sender?.getAttribute('data-message-sender') || '',
      text: own(el, '[data-qa="message-text"]')?.innerText || '',
      bot_id: own(el, APP_BADGE) ? 'unknown' : '',
      bot_profile: {},
    };
  }

  function describe(el) {
    const fromFiber = messageFromFiber(el);
    return describeMessage(fromFiber || messageFromDOM(el), el, !!fromFiber);
  }

  // Slack's own channel events: people joining or leaving, topic, purpose and
  // name changes, archiving, integrations added or removed, pins. One can
  // carry a bot id (bot_remove names the integration it removed), but Slack
  // wrote it, so it's never an app's post.
  const SLACK_EVENT = /^(?:channel|group)_|^bot_(?:add|remove|enable|disable)$|^(?:un)?pinned_item$/;

  /// Normalizes a Slack message object for matching. `el` is its rendered
  /// row when there is one; a reply read from Slack's store has none.
  function describeMessage(m, el = null, full = true) {
    if (!m || !m.ts) return null;
    const event = SLACK_EVENT.test(m.subtype || '');
    const profile = m.bot_profile || {};
    const senderEl = own(el, '[data-qa="message_sender_name"]');
    const signature = full ? signatureOf(m) : null;
    // Slack's client drops app_id from messages an app posted with a person's
    // token, so the "Sent using" footer is the usual tell.
    const onBehalf = !!m.user && !m.bot_id && (!!m.app_id || !!signature);
    const appId = profile.app_id || m.app_id || signature?.appId || '';
    const app = appId ? apps().byId.get(appId) : null;
    // Bot users seen posting, so a bot outside the app catalog is still known
    // when it shows up as a face in someone else's thread. A bot message can
    // carry a person's id too (legacy integrations post as their installer,
    // some apps post with a person's token); that person is no bot.
    if (m.bot_id) {
      knownBots.set(m.bot_id, appId);
      if (m.user && member(m.user)?.is_bot !== false) knownBots.set(m.user, appId);
    }
    return {
      ts: m.ts,
      channel: m.channel || el?.getAttribute('data-msg-channel-id') || '',
      user: m.user || '',
      name: (senderEl?.textContent || profile.name || '').trim(),
      botId: m.bot_id || '',
      appId,
      appName: app?.name || profile.name || '',
      icon: profile.icons?.image_72 || profile.icons?.image_48 || app?.icon || '',
      subtype: m.subtype || '',
      isApp: !event && (!!m.bot_id || !!own(el, APP_BADGE)),
      onBehalf,
      via: signature?.name || (onBehalf ? app?.name || '' : ''),
      text: m.text || '',
      metadata: m.metadata ? JSON.stringify(m.metadata) : '',
      blocks: Array.isArray(m.blocks) ? m.blocks.length : 0,
      threadTs: m.thread_ts || '',
      replyCount: Number(m.reply_count) || 0,
      latestReply: m.latest_reply || '',
      replyUsers: Array.isArray(m.reply_users) ? m.reply_users : [],
      replyUsersCount: Number(m.reply_users_count) || 0,
    };
  }

  // ------------------------------------------------------------------- rules
  const state = { rules: [], revealed: false, pick: false, stats: { messages: 0, matched: 0, byRule: {} } };

  function compile(rules) {
    return rules
      .filter((r) => r.enabled !== false)
      .map((r) => {
        let rx = null;
        if (r.match?.text) {
          try { rx = new RegExp(r.match.text, 'i'); } catch { rx = null; }
        }
        const via = (r.match?.via || []).map((v) => String(v).toLowerCase());
        return { ...r, _rx: rx, _via: via };
      });
  }

  const has = (list, value) => Array.isArray(list) && list.length > 0 && list.includes(value);

  function matches(rule, m) {
    const q = rule.match || {};
    if (q.anyApp && !(m.isApp || m.onBehalf)) return false;
    if (q.userIds?.length && !has(q.userIds, m.user)) return false;
    if (q.botIds?.length && !has(q.botIds, m.botId)) return false;
    if (q.appIds?.length && !has(q.appIds, m.appId)) return false;
    if (q.channelIds?.length && !has(q.channelIds, m.channel)) return false;
    if (q.subtypes?.length && !has(q.subtypes, m.subtype)) return false;
    if (q.names?.length && !q.names.some((n) => n.toLowerCase() === m.name.toLowerCase())) return false;
    if (rule._via.length && !rule._via.includes(m.via.toLowerCase())) return false;
    if (q.metadata && !m.metadata.includes(q.metadata)) return false;
    if (rule._rx && !rule._rx.test(m.text)) return false;
    // A rule with no constraints would swallow the whole workspace; ignore it.
    return !!(q.anyApp || q.userIds?.length || q.botIds?.length || q.appIds?.length || q.channelIds?.length ||
      q.subtypes?.length || q.names?.length || rule._via.length || q.metadata || rule._rx);
  }

  // The header already shows who sent the message, so the chip only names a
  // reason when it adds something: the tool that posted it, or a rule whose
  // name differs from the sender ("Apps", "AI tools").
  function reasonOf(rule, m) {
    if (m.onBehalf && m.via) return `via ${m.via}`;
    const name = String(rule.name || '').trim();
    const lower = name.toLowerCase();
    if (!name || lower === m.name.toLowerCase() || lower === m.appName.toLowerCase()) return '';
    return name;
  }

  function chipFor(rule, m, open) {
    const reason = reasonOf(rule, m);
    switch (rule.style) {
      case 'accordion': return open ? (reason ? `${reason} · Fold` : 'Fold') : `${reason || 'Folded'} · Show`;
      case 'blur': return reason ? `${reason} · Hover to read` : 'Hover to read';
      default: return reason || rule.name || 'Muted';
    }
  }

  // ------------------------------------------------------------- what we see
  // Apps and signatures observed in rendered messages, drained by the app.
  const seen = new Map();
  const counted = new Set();

  function tally(m) {
    if (!m.isApp && !m.onBehalf && !m.via) return;
    const id = `${m.channel}:${m.ts}`;
    if (counted.has(id)) return;
    counted.add(id);
    if (counted.size > 6000) counted.clear();

    const key = m.appId ? `app:${m.appId}` : m.botId && m.botId !== 'unknown' ? `bot:${m.botId}` :
      m.via ? `via:${m.via.toLowerCase()}` : null;
    if (!key) return;
    const entry = seen.get(key) || {
      key, appId: m.appId, botId: m.botId === 'unknown' ? '' : m.botId,
      name: m.onBehalf ? m.via || m.appName || m.name : m.appName || m.name, icon: m.icon, via: m.via,
      ids: [], onBehalf: 0,
    };
    entry.ids.push(id);
    if (m.onBehalf) entry.onBehalf++;
    if (!entry.icon && m.icon) entry.icon = m.icon;
    seen.set(key, entry);
  }

  // ------------------------------------------------------------------- apply
  const opened = new Set();

  function clearRow(row, { keepThread = false } = {}) {
    row.removeAttribute(A.style);
    row.removeAttribute(A.rule);
    row.removeAttribute(A.chip);
    row.removeAttribute(A.open);
    row.removeAttribute(A.hot);
    row.removeAttribute(A.lift);
    row.removeAttribute(A.fit);
    row.removeAttribute(A.cut);
    if (keepThread) return;
    row.removeAttribute(A.faces);
    row.removeAttribute(A.thread);
  }

  function setAttr(el, name, value) {
    if (el.getAttribute(name) !== value) el.setAttribute(name, value);
  }

  let compiled = [];
  function recompile() {
    compiled = state.revealed ? [] : compile(state.rules);
  }

  /// Styles one message. Returns the row and rule it matched, if any.
  function styleMessage(el) {
    const row = el.closest(ROW);
    if (!row) return null;
    const m = describe(el);
    if (!m) return null;
    tally(m);
    if (m.threadTs && m.threadTs !== m.ts) noteReply(m);
    // An allow rule ("none") is an exception: it wins like any rule, so a
    // broader rule further down never reaches the message, but mutes nothing.
    const matched = compiled.find((r) => matches(r, m));
    const rule = matched && matched.style !== 'none' ? matched : null;
    // Slop repliers' faces are muted in every thread preview, even under a
    // message that isn't slop itself.
    const kindOf = m.replyUsers.length ? replierKinds(m) : () => null;
    const faces = slopFaceList(el, kindOf);
    if (faces) setAttr(row, A.faces, faces);
    else if (row.hasAttribute(A.faces)) row.removeAttribute(A.faces);
    const thread = threadMute(el, m, kindOf);
    if (thread) setAttr(row, A.thread, thread);
    else if (row.hasAttribute(A.thread)) row.removeAttribute(A.thread);
    if (!rule) {
      if (row.hasAttribute(A.style)) clearRow(row, { keepThread: true });
      return { row, rule: null, folded: false };
    }
    const open = rule.style === 'accordion' && opened.has(m.ts);
    setAttr(row, A.style, rule.style);
    setAttr(row, A.rule, rule.id);
    setAttr(row, A.chip, chipId(chipFor(rule, m, open)));
    if (open) setAttr(row, A.open, '');
    else if (row.hasAttribute(A.open)) row.removeAttribute(A.open);
    const carded = CARD_HOSTS.includes(rule.style);
    if (!carded && row.hasAttribute(A.cut)) row.removeAttribute(A.cut);
    return { row, rule, folded: rule.style === 'accordion' && !open, carded };
  }

  // ----------------------------------------------------------- thread faces
  // A reply-bar face is muted when that replier is slop in this thread: they
  // match a rule on their own (an app or bot under an app rule, a person
  // under a person rule), or every reply of theirs here was made with a muted
  // tool ("Sent using Claude"). Tag never mutes anything, so a replier whose
  // rule is Tag keeps their face.

  function faceUser(face) {
    const img = face.querySelector('img') || face;
    let f = fiberOf(img);
    for (let depth = 0; f && depth < 8; depth++, f = f.return) {
      const id = f.memoizedProps?.userId;
      if (typeof id === 'string' && id) return id;
    }
    return img.getAttribute?.('src')?.match(/-([UW][A-Z0-9]{6,})-/)?.[1] || '';
  }

  /// How a described message would be muted: 'dim', 'gray', or null. Dim
  /// fades a face; every other muting style has no face equivalent (you
  /// can't fold or frost an avatar), so it gets Grayscale's treatment.
  function muteKind(m) {
    const rule = compiled.find((r) => matches(r, m));
    if (!rule || rule.style === 'outline' || rule.style === 'none') return null;
    return rule.style === 'dim' ? 'dim' : 'gray';
  }

  /// Slack's own record of a member, read only. It settles whether an id is a
  /// bot, which a message alone can't.
  function member(id) {
    return id ? slackStore()?.getState?.()?.members?.[id] || null : null;
  }

  /// `id` is whatever Slack shows a face for: a member id (U…/W…), or a bot id
  /// (B…) for bots that post without a user of their own.
  function repliesAsSlop(id, m) {
    const botId = /^B[A-Z0-9]+$/.test(id) ? id : '';
    const app = botId ? null : apps().byBotUser.get(id);
    const record = botId ? null : member(id);
    const isBot = !!botId || !!app || (record ? !!record.is_bot : knownBots.has(id));
    return muteKind({
      ts: '', channel: m.channel, user: botId ? '' : id, name: app?.name || '', botId,
      appId: app?.id || record?.profile?.api_app_id || knownBots.get(id) || '', appName: app?.name || '', icon: '',
      subtype: '', isApp: isBot, onBehalf: false, via: '',
      text: '', metadata: '', blocks: 0,
    });
  }

  // Replies seen in an open thread, by thread, so its preview knows how each
  // was sent. Bounded; the oldest threads go first.
  const MAX_THREADS = 400;
  const replyLog = new Map();

  function noteReply(m) {
    const key = `${m.channel}:${m.threadTs}`;
    const replies = replyLog.get(key) || new Map();
    replyLog.delete(key);
    replies.set(m.ts, m);
    replyLog.set(key, replies);
    if (replyLog.size > MAX_THREADS) replyLog.delete(replyLog.keys().next().value);
  }

  /// A message from Slack's store, read only. The store keeps the latest
  /// reply of every thread it previews, even ones never opened.
  function storedMessage(channel, ts) {
    return slackStore()?.getState?.()?.messages?.[channel]?.[ts] || null;
  }

  /// Each replier's mute kind in the thread under `m`. A replier's own rule
  /// decides first. Otherwise their replies do, but only when every reply in
  /// the thread is known: someone with one reply we can't see may have
  /// written it by hand.
  function replierKinds(m) {
    const known = new Map(replyLog.get(`${m.channel}:${m.ts}`) || []);
    if (m.latestReply && !known.has(m.latestReply)) {
      const reply = describeMessage(storedMessage(m.channel, m.latestReply));
      if (reply) known.set(reply.ts, reply);
    }
    const complete = m.replyCount > 0 && known.size >= m.replyCount;
    const byAuthor = new Map();
    if (complete) {
      for (const reply of known.values()) {
        const author = reply.user || reply.botId;
        byAuthor.set(author, [...(byAuthor.get(author) || []), muteKind(reply)]);
      }
    }
    return (id) => {
      const own = repliesAsSlop(id, m);
      if (own) return own;
      const kinds = byAuthor.get(id);
      if (!kinds || kinds.some((kind) => !kind)) return null;
      return kinds.includes('gray') ? 'gray' : 'dim';
    };
  }

  /// How to mute a thread's reply count, or '' to leave it alone. Only when
  /// every replier is slop: one person in the thread and the count stays.
  /// Slack lists at most a few repliers next to a total; if the total is
  /// larger than the list, not everyone can be checked, so it stays too. The
  /// count takes the repliers' look: gray if any of them is gray, else dim.
  function threadMute(el, m, kindOf) {
    const users = m.replyUsers;
    if (!users.length || !el.querySelector(REPLY_BAR)) return '';
    if (m.replyUsersCount > users.length) return '';
    const kinds = users.map(kindOf);
    if (kinds.some((kind) => !kind)) return '';
    return kinds.includes('gray') ? 'gray' : 'dim';
  }

  function slopFaceList(el, kindOf) {
    const bar = el.querySelector('.c-message__reply_bar');
    if (!bar) return '';
    const out = [];
    [...bar.children].slice(0, MAX_FACES).forEach((face, i) => {
      if (!face.classList.contains('c-message__reply_bar_avatar')) return;
      const userId = faceUser(face);
      const kind = userId ? kindOf(userId) : null;
      if (kind) out.push(`${i + 1}-${kind}`);
    });
    return out.join(' ');
  }

  /// Restyles the given messages, then aligns chips on the folded ones and
  /// sizes cards. Writes first, then reads, so layout is computed once.
  function styleMessages(elements, alignAll = true) {
    const folded = [];
    const carded = [];
    for (const el of elements) {
      if (!el.isConnected) continue;
      const result = styleMessage(el);
      if (result?.folded && (alignAll || !result.row.hasAttribute(A.lift))) folded.push(result.row);
      if (result?.carded) carded.push(result.row);
    }
    align(folded);
    sizeCards(carded, true);
  }

  /// Everything on screen, plus stats and theme. Used when rules change and
  /// as a slow safety net; new rows take the fast path below.
  function styleAll() {
    detectTheme();
    const stats = { messages: 0, matched: 0, byRule: {} };
    const folded = [];
    const carded = [];
    for (const el of document.querySelectorAll(MSG)) {
      const result = styleMessage(el);
      if (!result) continue;
      stats.messages++;
      if (!result.rule) continue;
      stats.matched++;
      stats.byRule[result.rule.id] = (stats.byRule[result.rule.id] || 0) + 1;
      if (result.folded && !result.row.hasAttribute(A.lift)) folded.push(result.row);
      if (result.carded) carded.push(result.row);
    }
    align(folded);
    sizeCards(carded, false);
    state.stats = stats;
  }

  // ------------------------------------------------------------- alignment
  // A folded chip floats beside the first line, so CSS can't baseline-align
  // it. Measure the line's baseline from the first rendered text and the font
  // metrics, lift the chip by whole pixels until the baselines match, and fit
  // the fold to the line's real height so nothing on it, chip included, clips.
  const metricCache = new Map();
  let measureContext = null;
  function fontMetrics(font) {
    let m = metricCache.get(font);
    if (m) return m;
    measureContext ||= document.createElement('canvas').getContext('2d');
    measureContext.font = font;
    const t = measureContext.measureText('Hg');
    m = { ascent: t.fontBoundingBoxAscent, descent: t.fontBoundingBoxDescent };
    metricCache.set(font, m);
    return m;
  }

  const CHIP_FONT = '500 11px -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif';
  // CHIP_LINE, MIN_FIT, MAX_FIT and MAX_LIFT live at the top with the styles.

  function chipBaseline() {
    const m = fontMetrics(CHIP_FONT);
    return (CHIP_LINE - (m.ascent + m.descent)) / 2 + m.ascent;
  }

  function firstTextRect(body) {
    const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT, {
      acceptNode: (n) => (n.textContent.trim() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP),
    });
    const range = document.createRange();
    for (let node = walker.nextNode(), tries = 0; node && tries < 6; node = walker.nextNode(), tries++) {
      range.selectNodeContents(node);
      const rect = [...range.getClientRects()].find((r) => r.width > 0 && r.height > 0);
      if (rect) return { rect, el: node.parentElement };
    }
    return null;
  }

  function measureFold(row) {
    const body = row.querySelector(FIRST_BODY);
    const text = body && firstTextRect(body);
    if (!text) return { lift: 1, fit: MIN_FIT };
    const top = body.getBoundingClientRect().top;
    const style = getComputedStyle(text.el);
    const font = `${style.fontStyle} ${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
    const baseline = text.rect.top - top + fontMetrics(font).ascent;
    const lift = Math.max(0, Math.min(MAX_LIFT, Math.round(baseline - chipBaseline())));

    // Where the first line ends: its line box, pushed down by anything taller
    // on it (an emoji, a mention pill, inline code) and by the chip, but never
    // past the top of the second line, so nothing below ever peeks in.
    const lineHeight = parseFloat(style.lineHeight) || text.rect.height;
    let bottom = Math.max(
      text.rect.top - (lineHeight - text.rect.height) / 2 + lineHeight,
      top + lift + CHIP_LINE + 1,
    );
    let nextLineTop = Infinity;
    const range = document.createRange();
    range.selectNodeContents(text.el.closest('p, li, div, section') || body);
    for (const r of range.getClientRects()) {
      if (r.height === 0 || r.height > 40) continue; // block boxes
      if (r.top >= text.rect.bottom - 0.5) nextLineTop = Math.min(nextLineTop, r.top);
      else bottom = Math.max(bottom, r.bottom);
    }
    const fit = Math.round(Math.min(bottom, nextLineTop) - top);
    return { lift, fit: Math.max(MIN_FIT, Math.min(MAX_FIT, fit)) };
  }

  function align(rows) {
    if (!rows.length) return;
    const fits = rows.map(measureFold); // reads
    rows.forEach((row, i) => { // writes
      setAttr(row, A.lift, String(fits[i].lift));
      setAttr(row, A.fit, String(fits[i].fit));
    });
  }

  // ------------------------------------------------------------------ cards
  // A card taller than CARD_LINES lines is cut at the last whole line, with
  // "Show more" under it. Each cut is measured once and kept in generated
  // CSS keyed by data-sd-cut, like chips, so Slack's nodes stay untouched.
  const expanded = new Set();
  const cutIds = new Map(); // "index:px:top:left" → id
  const cutsById = new Map(); // id → { index, px, top, left }

  /// The cut part ends at its last whole line and clips exactly at its
  /// content edge, so its padding stays clear for the link. The link is the
  /// column's ::after, placed from the column's offset parent: a pseudo of
  /// the cut part would be cut off with it (Grayscale's filter makes the part
  /// its containing block).
  function cutId(cut) {
    const key = `${cut.index}:${cut.px}:${cut.top}:${cut.left}`;
    let id = cutIds.get(key);
    if (id) return id;
    id = `c${cutIds.size + 1}`;
    cutIds.set(key, id);
    cutsById.set(id, cut);
    let el = document.getElementById('sd-cuts');
    if (!el) {
      el = document.createElement('style');
      el.id = 'sd-cuts';
      (document.head || ROOT).appendChild(el);
    }
    const row = `${CARDED}[${A.cut}="${id}"][${A.cut}="${id}"]`;
    const part = `${row} ${RIGHT} > :nth-child(${cut.index})`;
    for (const rule of [
      `${part} { ${CARD_BOTTOM} padding-bottom: ${LINK_ROOM}px !important; max-height: ${cut.px}px; overflow: clip; overflow-clip-margin: content-box; }`,
      `${part} ~ ${BODY} { display: none !important; }`,
      `${row} ${RIGHT}::after { ${LINK} content: 'Show more'; top: ${cut.top}px; left: ${cut.left}px; background-image: var(--sd-more); }`,
    ]) {
      try { el.sheet.insertRule(rule, el.sheet.cssRules.length); } catch (err) { console.warn('[slopdrop]', err); }
    }
    return id;
  }

  function contentBox(el) {
    const r = el.getBoundingClientRect();
    const s = getComputedStyle(el);
    return {
      top: r.top + parseFloat(s.borderTopWidth) + parseFloat(s.paddingTop),
      bottom: r.bottom - parseFloat(s.borderBottomWidth) - parseFloat(s.paddingBottom),
      left: r.left + parseFloat(s.borderLeftWidth) + parseFloat(s.paddingLeft),
    };
  }

  /// Where a card's cut goes, measured at its natural height; null when it
  /// fits in CARD_LINES lines or would hide less than CARD_MIN_HIDDEN.
  function measureCut(row) {
    const right = row.querySelector(RIGHT);
    const origin = right?.offsetParent;
    if (!origin) return null;
    const children = [...right.children];
    const parts = children.filter((c) => c.matches(BODY));
    if (!parts.length) return null;
    const limit = contentBox(parts[0]).top + CARD_LINES * CARD_LINE;
    if (contentBox(parts[parts.length - 1]).bottom - limit < CARD_MIN_HIDDEN) return null;
    let i = parts.findIndex((p) => contentBox(p).bottom > limit);
    if (i < 0) return null;
    let box = contentBox(parts[i]);
    // End on the last line that's whole by the limit, never through one.
    let px = limit - box.top;
    let lastLine = 0;
    const range = document.createRange();
    range.selectNodeContents(parts[i]);
    for (const r of range.getClientRects()) {
      if (r.height > 0 && r.height <= 2 * CARD_LINE && r.bottom <= limit + 0.5) {
        lastLine = Math.max(lastLine, r.bottom - box.top);
      }
    }
    if (lastLine > 0) px = lastLine;
    // Barely any of this part would show: end the card on the one before.
    if (px < CARD_LINE && i > 0) {
      i -= 1;
      box = contentBox(parts[i]);
      px = box.bottom - box.top;
    }
    px = Math.max(CARD_LINE, Math.ceil(px));
    const o = origin.getBoundingClientRect();
    return {
      index: children.indexOf(parts[i]) + 1,
      px,
      top: Math.round(box.top + px + LINK_GAP - o.top - origin.clientTop),
      left: Math.round(box.left - o.left - origin.clientLeft),
    };
  }

  /// Measures carded rows and applies their cut. With `force`, every row is
  /// measured again (it just changed); otherwise only new and short ones,
  /// which may have grown as images loaded. A cut row is released first so
  /// it's measured at its natural height; all in one task, so nothing paints
  /// in between.
  function sizeCards(rows, force) {
    const todo = force ? rows : rows.filter((row) => (row.getAttribute(A.cut) || 'fit') === 'fit');
    if (!todo.length) return;
    for (const row of todo) if (cutsById.has(row.getAttribute(A.cut))) row.removeAttribute(A.cut);
    const found = todo.map(measureCut); // reads
    todo.forEach((row, i) => { // writes
      const ts = row.querySelector(MSG)?.getAttribute('data-msg-ts') || '';
      const cut = found[i];
      setAttr(row, A.cut, !cut ? 'fit' : expanded.has(ts) ? 'open' : cutId(cut));
    });
  }

  function linkWidth(text) {
    measureContext ||= document.createElement('canvas').getContext('2d');
    measureContext.font = LINK_FONT;
    return measureContext.measureText(text).width + LINK_CHEVRON;
  }

  /// Where "Show more" or "Show less" is drawn, in viewport coordinates.
  function linkRect(row) {
    const value = row.getAttribute(A.cut);
    const right = row.querySelector(RIGHT);
    if (!right || !value || value === 'fit') return null;
    let left;
    let top;
    if (value === 'open') {
      const last = [...right.children].filter((c) => c.matches(BODY)).pop();
      if (!last) return null;
      const r = last.getBoundingClientRect();
      left = r.left + last.clientLeft + CARD_PAD;
      top = r.bottom - 1 - 10 - LINK_LINE;
    } else {
      const cut = cutsById.get(value);
      const origin = right.offsetParent;
      if (!cut || !origin) return null;
      const o = origin.getBoundingClientRect();
      left = o.left + origin.clientLeft + cut.left;
      top = o.top + origin.clientTop + cut.top;
    }
    return { left, top, right: left + linkWidth(value === 'open' ? 'Show less' : 'Show more'), bottom: top + LINK_LINE };
  }

  // Forgiving by 6px on every side, like the chip.
  function linkHit(row, x, y) {
    const r = linkRect(row);
    const pad = 6;
    return !!r && x >= r.left - pad && x <= r.right + pad && y >= r.top - pad && y <= r.bottom + pad;
  }

  function toggleCard(ts) {
    if (expanded.has(ts)) expanded.delete(ts); else expanded.add(ts);
    setHot(null);
    styleMessages(document.querySelectorAll(`${MSG}[data-msg-ts="${CSS.escape(ts)}"]`));
  }

  // ------------------------------------------------------------- scheduling
  // Slack's list mounts rows a little beyond the viewport and recycles them as
  // you scroll. Mutation observer callbacks run after Slack inserts a row but
  // before the browser paints it, so styling new rows right here means a row
  // is never painted unstyled, however fast you scroll. Only rows that changed
  // are touched; a slower full pass keeps stats and theme current.
  function collect(record, into) {
    const target = record.target.nodeType === 1 ? record.target : record.target.parentElement;
    const host = target?.closest?.(MSG);
    if (host) into.add(host);
    if (record.type !== 'childList') return;
    for (const node of record.addedNodes) {
      if (node.nodeType !== 1) continue;
      if (node.matches(MSG)) into.add(node);
      else for (const el of node.querySelectorAll(MSG)) into.add(el);
    }
  }

  const observer = new MutationObserver((records) => {
    const dirty = new Set();
    for (const record of records) collect(record, dirty);
    if (dirty.size) {
      try { styleMessages(dirty); } catch (err) { console.warn('[slopdrop]', err); }
    }
    scheduleFull();
  });
  observer.observe(ROOT, {
    childList: true, subtree: true, attributes: true,
    attributeFilter: ['data-qa', 'data-msg-ts', 'data-qa-placeholder', 'data-qa-unprocessed'],
  });

  // Timers, not requestAnimationFrame: rAF stops while Slack is occluded.
  let fullTimer = 0;
  function scheduleFull() {
    if (fullTimer) return;
    fullTimer = setTimeout(() => {
      fullTimer = 0;
      try { styleAll(); } catch (err) { console.warn('[slopdrop]', err); }
    }, 250);
  }
  const safetyNet = setInterval(scheduleFull, 2000);

  function restyleNow() {
    recompile();
    ensureStyles();
    try { styleAll(); } catch (err) { console.warn('[slopdrop]', err); }
  }

  // The chip is a pseudo-element, so find it through its host: the floated
  // ::before of the first body part, or the trailing ::after when a message
  // has no body part we recognise.
  function chipRect(row) {
    const body = row.querySelector(FIRST_BODY);
    const host = body || row.querySelector(RIGHT);
    if (!host) return null;
    const pseudo = getComputedStyle(host, body ? '::before' : '::after');
    const width = (parseFloat(pseudo.width) || 0) + (parseFloat(pseudo.paddingLeft) || 0) + (parseFloat(pseudo.paddingRight) || 0);
    const height = parseFloat(pseudo.height) || parseFloat(pseudo.lineHeight) || 0;
    if (!(width > 0 && height > 0)) return null;
    const r = host.getBoundingClientRect();
    const top = body ? r.top + (parseFloat(pseudo.marginTop) || 0) : r.bottom - height;
    return { left: r.left, top, right: r.left + width, bottom: top + height };
  }

  // Forgiving by 6px on every side, so it's a target, not a pixel hunt.
  function chipHit(row, x, y) {
    const c = chipRect(row);
    const pad = 6;
    return !!c && x >= c.left - pad && x <= c.right + pad && y >= c.top - pad && y <= c.bottom + pad;
  }

  // Fold toggles on a click anywhere on the message, both ways, immediately.
  // A press that moves before it's released is a drag-select and never
  // toggles, and neither does a click while text is selected in the message.
  // Slack's own controls always win: links, mentions, buttons, images, the
  // toolbar, the sender's name and avatar, the timestamp.
  const SLACK_CONTROL = [
    '.c-message_actions__container', 'a', 'button', '[role="button"]', '[role="link"]',
    'input', 'textarea', '[contenteditable="true"]', 'img', 'video',
  ].join(', ');
  const isSlackControl = (target) => !!target?.closest?.(SLACK_CONTROL);
  // How far a press may travel and still count as a click, not a drag.
  const DRAG_PX = 4;

  // hot: "row" (folded; any click unfolds), "chip" (open; the chip folds it),
  // "body" (open; a click on the message folds it). The chip lights for all
  // three; the cursor only turns into a pointer where clicking can't select.
  let hotRow = null;
  let hotKind = null;
  let pointer = null;
  let hoverFrame = 0;

  function setHot(row, kind = null) {
    if (hotRow === row && hotKind === kind) return;
    if (hotRow && hotRow !== row) hotRow.removeAttribute(A.hot);
    hotRow = row;
    hotKind = row ? kind : null;
    if (row) row.setAttribute(A.hot, kind);
  }

  function updateHot() {
    hoverFrame = 0;
    if (!pointer || state.pick) return setHot(null);
    const card = pointer.target?.closest?.(`${ROW}[${A.cut}]`);
    if (card && linkHit(card, pointer.x, pointer.y)) return setHot(card, 'more');
    const row = pointer.target?.closest?.(S('accordion'));
    if (!row || isSlackControl(pointer.target)) return setHot(null);
    if (!row.hasAttribute(A.open)) return setHot(row, 'row');
    setHot(row, chipHit(row, pointer.x, pointer.y) ? 'chip' : 'body');
  }

  function onPointerMove(e) {
    pointer = { target: e.target, x: e.clientX, y: e.clientY };
    if (!hoverFrame) hoverFrame = requestAnimationFrame(updateHot);
  }

  function onPointerOut(e) {
    if (!e.relatedTarget) { pointer = null; setHot(null); }
  }

  // Where the last press started, to tell a click-and-place from a drag.
  let press = null;
  function onPointerDown(e) {
    if (e.button === 0) press = { x: e.clientX, y: e.clientY };
  }
  const wasDrag = (e) => !!press && Math.hypot(e.clientX - press.x, e.clientY - press.y) > DRAG_PX;

  function selectingIn(row) {
    const selection = getSelection();
    return !!selection && !selection.isCollapsed && !!selection.toString().trim() &&
      row.contains(selection.anchorNode);
  }

  function toggle(ts) {
    if (opened.has(ts)) opened.delete(ts); else opened.add(ts);
    setHot(null);
    // The same message can be on screen twice (channel and thread); both flip.
    styleMessages(document.querySelectorAll(`${MSG}[data-msg-ts="${CSS.escape(ts)}"]`));
  }

  function onClick(e) {
    if (state.pick) {
      const el = e.target.closest?.(MSG);
      if (!el) return;
      e.preventDefault();
      e.stopPropagation();
      const m = describe(el);
      if (m) api.picked = m;
      return;
    }
    // "Show more" / "Show less" on a card: drawn by CSS, so hit-tested here.
    const card = e.target.closest?.(`${ROW}[${A.cut}]`);
    if (card && linkHit(card, e.clientX, e.clientY)) {
      const ts = card.querySelector(MSG)?.getAttribute('data-msg-ts');
      if (!ts) return;
      e.preventDefault();
      e.stopPropagation();
      if (!wasDrag(e) && e.detail <= 1) toggleCard(ts);
      return;
    }
    const row = e.target.closest?.(`${S('accordion')}`);
    if (!row || isSlackControl(e.target)) return;
    const ts = row.querySelector(MSG)?.getAttribute('data-msg-ts');
    if (!ts) return;
    // A drag-select, or the second click of a double-click: the first click
    // already toggled, so a double-click never bounces the message.
    if (wasDrag(e) || e.detail > 1) return;

    if (!opened.has(ts) || chipHit(row, e.clientX, e.clientY)) {
      e.preventDefault();
      e.stopPropagation();
      toggle(ts);
      return;
    }
    // Open, and the click landed on the message itself. Leave an existing
    // selection alone (e.g. shift-click to extend it); otherwise fold.
    if (!selectingIn(row)) toggle(ts);
  }
  document.addEventListener('pointerdown', onPointerDown, { capture: true, passive: true });
  document.addEventListener('click', onClick, true);
  document.addEventListener('pointermove', onPointerMove, { capture: true, passive: true });
  document.addEventListener('pointerout', onPointerOut, { capture: true, passive: true });

  // -------------------------------------------------------------- public api
  const api = {
    version: VERSION,
    picked: null,
    styles: Object.entries(STYLES).map(([id, s]) => ({ id, title: s.title, blurb: s.blurb })),

    setRules(rules) {
      state.rules = Array.isArray(rules) ? rules : [];
      restyleNow();
      return state.stats;
    },

    configure({ revealed, pick }) {
      if (typeof revealed === 'boolean') state.revealed = revealed;
      if (typeof pick === 'boolean') {
        state.pick = pick;
        ROOT.setAttribute('data-sd-pick', pick ? 'on' : 'off');
        if (pick) api.picked = null;
      }
      restyleNow();
      return state.stats;
    },

    getStats() {
      return { ...state.stats, rules: state.rules.length, pick: state.pick, picked: api.picked };
    },

    /// Observations since the last call.
    takeSeen() {
      const out = [...seen.values()];
      seen.clear();
      return out;
    },

    /// Installed apps that can post, with Slack's own AI/agent flags.
    catalog() {
      return [...apps().byId.values()].filter((a) => a.botUserId);
    },

    health() {
      const el = document.querySelector(MSG);
      return {
        version: VERSION,
        messages: document.querySelectorAll(MSG).length,
        fiber: el ? !!messageFromFiber(el) : false,
        store: !!slackStore(),
        href: location.pathname,
      };
    },

    dispose() {
      observer.disconnect();
      clearTimeout(fullTimer);
      clearInterval(safetyNet);
      document.removeEventListener('pointerdown', onPointerDown, true);
      document.removeEventListener('click', onClick, true);
      document.removeEventListener('pointermove', onPointerMove, true);
      document.removeEventListener('pointerout', onPointerOut, true);
      document.querySelectorAll(`[${A.style}], [${A.faces}], [${A.thread}]`).forEach((row) => clearRow(row));
      document.getElementById('sd-styles')?.remove();
      document.getElementById('sd-chips')?.remove();
      document.getElementById('sd-cuts')?.remove();
      ROOT.removeAttribute('data-sd-pick');
      ROOT.removeAttribute('data-sd-theme');
    },
  };
  window.__slop = api;

  restyleNow();
  console.log('[slopdrop] agent v' + VERSION + ' ready');
})();
