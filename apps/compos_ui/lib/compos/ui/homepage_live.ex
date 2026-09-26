defmodule Compos.Ui.HomepageLive do
  use Phoenix.LiveView
  import Compos.Ui.ComposML, only: [sigil_M: 2]

  @palettes ~w(ultraviolet phosphor ember monochrome)
  @motifs ~w(lambda swan)

  @impl true
  def mount(_params, _session, socket) do
    brand = %{
      name: "Compos",
      wordmark: "compos",
      eyebrow: "COMPOS / QUIET COMPUTING ENVIRONMENT",
      email: "hello@compos.in",
      tagline: "The Hackable Harness for Power Users"
    }

    {:ok,
     assign(socket,
       brand: brand,
       palette: "ultraviolet",
       motif: "lambda",
       page_title: "#{brand.name} — #{brand.tagline}"
     )}
  end

  @impl true
  def handle_event("set-palette", %{"palette" => palette}, socket) when palette in @palettes do
    {:noreply, assign(socket, palette: palette)}
  end

  @impl true
  def handle_event("set-motif", %{"motif" => motif}, socket) when motif in @motifs do
    {:noreply, assign(socket, motif: motif)}
  end

  def composml(assigns) do
    ~M"""
    <main class={["home-site", "compos-site", "palette-#{@palette}"]}>
      <style>
        body:has(.home-site) {
          overflow: auto;
          background: #06070a;
          color: #ece9df;
        }

        .home-site {
          --void: #06070a;
          --ink: #0b0c12;
          --panel: #11121a;
          --paper: #ece9df;
          --muted: #9897a5;
          --violet: #9784ff;
          --cyan: #71dcff;
          --glow: rgba(92, 70, 220, 0.12);
          --emblem-filter: saturate(0.78) contrast(1.12);
          --mark-blue: #376fc2;
          --mark-ochre: #cf8e35;
          --mark-rose: #bd716d;
          --mark-violet: #655070;
          --mark-cyan: #45bfd1;
          --mark-ivory: #e7ddc6;
          --hairline: rgba(236, 233, 223, 0.13);
          min-height: 100vh;
          overflow: hidden;
          background:
            radial-gradient(circle at 76% 10%, var(--glow), transparent 26rem),
            var(--void);
          color: var(--paper);
          font: 400 16px/1.55 var(--font-sans);
        }

        .home-site a { color: inherit; text-decoration: none; }
        .home-shell { width: min(1480px, calc(100% - 48px)); margin: 0 auto; }

        .home-nav {
          position: relative;
          z-index: 10;
          display: flex;
          align-items: center;
          justify-content: space-between;
          height: 76px;
          border-bottom: 1px solid var(--hairline);
        }

        .home-brand { display: flex; align-items: center; gap: 12px; }
        .home-brand img { width: 38px; height: 38px; border-radius: 11px; }
        .home-brand .compos-logo-image { width: 42px; height: 42px; }
        .home-brand c-text { font-size: 20px; font-weight: 500; letter-spacing: -0.04em; }
        .home-brand .compos-wordmark {
          color: #d8d5df;
          font: 500 17px/1 var(--font-mono);
          letter-spacing: -0.045em;
        }
        .home-nav-links { display: flex; align-items: center; gap: 30px; color: #aaa9b4; font-size: 14px; }
        .home-nav-links a { transition: color 160ms ease; }
        .home-nav-links a:hover { color: var(--paper); }

        .home-button {
          display: inline-flex;
          align-items: center;
          justify-content: center;
          min-height: 48px;
          padding: 0 22px;
          border: 1px solid rgba(236, 233, 223, 0.2);
          border-radius: 0;
          background: rgba(236, 233, 223, 0.06);
          font-size: 14px;
          font-weight: 500;
          transition: transform 160ms ease, background 160ms ease, border-color 160ms ease;
        }

        .home-button:hover { transform: translateY(-2px); border-color: rgba(236, 233, 223, 0.5); }
        .home-button.primary { border-color: var(--paper); background: var(--paper); color: #101116; }
        .home-button.primary:hover { background: white; }

        .home-hero {
          position: relative;
          display: grid;
          grid-template-columns: minmax(390px, 0.78fr) minmax(580px, 1.22fr);
          align-items: center;
          min-height: 770px;
          padding: 92px 0 108px;
        }

        .home-hero-copy { position: relative; z-index: 2; }
        .home-eyebrow {
          display: inline-flex;
          align-items: center;
          gap: 10px;
          margin-bottom: 25px;
          color: #b7b5c0;
          font-size: 12px;
          font-weight: 600;
          letter-spacing: 0.12em;
          text-transform: uppercase;
        }

        .home-eyebrow::before {
          width: 7px;
          height: 7px;
          border-radius: 50%;
          background: var(--violet);
          box-shadow: 0 0 14px rgba(151, 132, 255, 0.8);
          content: "";
        }

        .home-hero h1 {
          max-width: 670px;
          font: 450 clamp(58px, 6.6vw, 100px)/0.96 var(--font-sans);
          letter-spacing: -0.075em;
        }

        .home-hero h1 c-text {
          display: block;
          background: linear-gradient(100deg, #f5f2e9 12%, #9e99b8 92%);
          -webkit-background-clip: text;
          background-clip: text;
          color: transparent;
        }

        .compos-site .home-hero h1 .compos-aspect { display: inline; }

        .home-hero-subline {
          margin-top: 22px;
          color: #cac7d1;
          font: 500 clamp(18px, 2vw, 22px)/1.4 var(--font-mono);
          letter-spacing: -0.02em;
        }

        .home-hero-lede {
          max-width: 610px;
          margin: 32px 0 34px;
          color: #aaa9b4;
          font-size: clamp(18px, 2vw, 21px);
          line-height: 1.55;
          letter-spacing: -0.018em;
        }
        .home-hero-lede strong { color: #eeebe3; font-weight: 500; }

        .home-actions { display: flex; flex-wrap: wrap; gap: 12px; }
        .home-hero-note { max-width: 520px; margin-top: 38px; color: #676672; font: 500 11px/1.8 var(--font-mono); }
        .home-hero-art { position: relative; min-height: 620px; }
        .home-orbit {
          position: absolute;
          top: 50%;
          left: 50%;
          width: min(640px, 52vw);
          aspect-ratio: 1;
          transform: translate(-43%, -50%);
          border: 1px solid rgba(151, 132, 255, 0.18);
          border-radius: 50%;
          box-shadow: 0 0 110px rgba(85, 61, 210, 0.16);
        }

        .home-orbit::before,
        .home-orbit::after {
          position: absolute;
          border: 1px solid rgba(236, 233, 223, 0.08);
          border-radius: 50%;
          content: "";
        }

        .home-orbit::before { inset: 9%; }
        .home-orbit::after { inset: 22%; border-style: dashed; }
        .home-fractal {
          position: absolute;
          z-index: 1;
          top: 50%;
          left: 50%;
          width: min(610px, 50vw);
          transform: translate(-43%, -50%);
          mix-blend-mode: screen;
          filter: saturate(0.86) contrast(1.08);
          animation: home-breathe 10s ease-in-out infinite;
        }

        .compos-site .home-fractal {
          width: min(680px, 55vw);
          transform: translate(-43%, -50%);
          mix-blend-mode: normal;
          animation: compos-hue-drift 28s ease-in-out infinite alternate;
        }

        @keyframes compos-hue-drift {
          0% { filter: hue-rotate(-5deg) saturate(0.92) brightness(0.97); }
          48% { filter: hue-rotate(2deg) saturate(1) brightness(1); }
          100% { filter: hue-rotate(8deg) saturate(0.96) brightness(0.99); }
        }

        .compos-symbolic-svg { overflow: visible; }
        .compos-symbolic-svg .mark-base { opacity: 0.48; }
        .compos-symbolic-svg .pigment-surface {
          filter: url(#compos-pigment);
        }
        .compos-symbolic-svg .paper-grain {
          opacity: 0.2;
          mix-blend-mode: soft-light;
          pointer-events: none;
        }
        .compos-symbolic-svg .mark-contour {
          fill: none;
          stroke: rgba(235, 228, 214, 0.13);
          stroke-width: 3;
          vector-effect: non-scaling-stroke;
        }
        .compos-symbolic-svg .color-field {
          transform-box: fill-box;
          transform-origin: center;
          mix-blend-mode: screen;
        }
        .compos-symbolic-svg .color-field-a { animation: compos-swirl-a 16s ease-in-out infinite alternate; }
        .compos-symbolic-svg .color-field-b { animation: compos-swirl-b 21s ease-in-out infinite alternate; }
        .compos-symbolic-svg .color-field-c { animation: compos-swirl-c 27s linear infinite; }
        .compos-symbolic-svg .composition-core {
          transform-box: fill-box;
          transform-origin: center;
          animation: compos-core 8s ease-in-out infinite;
        }
        .compos-symbolic-svg .lambda-output {
          transform-box: fill-box;
          transform-origin: center;
          animation: compos-lambda 10s ease-in-out infinite;
          filter: url(#compos-pigment);
          mix-blend-mode: screen;
        }

        @keyframes compos-swirl-a {
          from { transform: translate(-5%, 3%) rotate(-16deg) scale(1.08); }
          to { transform: translate(8%, -6%) rotate(34deg) scale(1.24); }
        }

        @keyframes compos-swirl-b {
          from { transform: translate(7%, -4%) rotate(12deg) scale(1.16); }
          to { transform: translate(-7%, 7%) rotate(-42deg) scale(1.02); }
        }

        @keyframes compos-swirl-c {
          from { transform: rotate(0deg) scale(1.08); }
          50% { transform: rotate(180deg) scale(1.28); }
          to { transform: rotate(360deg) scale(1.08); }
        }

        @keyframes compos-core {
          0%, 100% { transform: scale(0.92); opacity: 0.82; }
          50% { transform: scale(1.08); opacity: 1; }
        }

        @keyframes compos-lambda {
          0%, 100% { transform: scale(0.94) rotate(-2deg); opacity: 0.82; }
          50% { transform: scale(1.04) rotate(2deg); opacity: 1; }
        }

        .compos-site .home-orbit { opacity: 0.34; }
        .compos-site .home-eyebrow::before { border-radius: 0; transform: rotate(45deg); }

        .compos-site.palette-phosphor {
          --violet: #76d39b;
          --cyan: #98efd0;
          --glow: rgba(49, 170, 112, 0.11);
          --emblem-filter: hue-rotate(232deg) saturate(0.62) contrast(1.14);
          --mark-blue: #318c72;
          --mark-ochre: #a7c96e;
          --mark-rose: #5faa82;
          --mark-violet: #3e695d;
          --mark-cyan: #98efd0;
          --mark-ivory: #d9e9d8;
        }

        .compos-site.palette-ember {
          --violet: #e69b62;
          --cyan: #f1c778;
          --glow: rgba(195, 92, 42, 0.1);
          --emblem-filter: hue-rotate(128deg) saturate(0.72) contrast(1.12) sepia(0.16);
          --mark-blue: #9d5745;
          --mark-ochre: #e0a051;
          --mark-rose: #cf6650;
          --mark-violet: #743f49;
          --mark-cyan: #f1c778;
          --mark-ivory: #ead8bb;
        }

        .compos-site.palette-monochrome {
          --violet: #dad7ce;
          --cyan: #9c9ba2;
          --glow: rgba(218, 215, 206, 0.07);
          --emblem-filter: grayscale(1) saturate(0) contrast(1.2) brightness(0.94);
          --mark-blue: #a9a8a3;
          --mark-ochre: #d3d0c7;
          --mark-rose: #8f8e8a;
          --mark-violet: #666661;
          --mark-cyan: #e3e0d6;
          --mark-ivory: #f0ede4;
        }

        .palette-dock {
          position: absolute;
          right: 1.5%;
          bottom: 2%;
          z-index: 4;
          display: flex;
          align-items: center;
          gap: 5px;
          padding: 6px;
          border: 1px solid var(--hairline);
          background: rgba(6, 7, 10, 0.72);
          backdrop-filter: blur(14px);
        }

        .motif-dock {
          position: absolute;
          right: 1.5%;
          bottom: 10%;
          z-index: 4;
          display: flex;
          align-items: center;
          gap: 5px;
          padding: 6px;
          border: 1px solid var(--hairline);
          background: rgba(6, 7, 10, 0.72);
          backdrop-filter: blur(14px);
        }

        .motif-dock > c-text {
          padding: 0 8px 0 4px;
          color: #656471;
          font: 500 9px/1 var(--font-mono);
          letter-spacing: 0.12em;
          text-transform: uppercase;
        }

        .motif-button {
          min-width: 38px;
          height: 31px;
          padding: 0 8px;
          border: 1px solid transparent;
          background: transparent;
          color: #777683;
          font: 500 11px/1 var(--font-mono);
          cursor: pointer;
        }

        .motif-button:hover,
        .motif-button.active {
          border-color: color-mix(in srgb, var(--violet), transparent 42%);
          color: var(--paper);
        }

        .palette-dock > c-text {
          padding: 0 8px 0 4px;
          color: #656471;
          font: 500 9px/1 var(--font-mono);
          letter-spacing: 0.12em;
          text-transform: uppercase;
        }

        .palette-swatch {
          display: grid;
          width: 31px;
          height: 31px;
          padding: 0;
          place-items: center;
          border: 1px solid transparent;
          background: transparent;
          cursor: pointer;
        }

        .palette-swatch::before {
          width: 10px;
          height: 10px;
          border-radius: 50%;
          background: var(--swatch);
          box-shadow: 0 0 9px color-mix(in srgb, var(--swatch), transparent 34%);
          content: "";
        }

        .palette-swatch:hover,
        .palette-swatch.active { border-color: color-mix(in srgb, var(--swatch), transparent 40%); }

        @keyframes home-breathe {
          0%, 100% { transform: translate(-43%, -50%) scale(0.985); opacity: 0.9; }
          50% { transform: translate(-43%, -50%) scale(1.015); opacity: 1; }
        }

        .home-proof {
          position: relative;
          z-index: 3;
          margin-top: 0;
          padding-bottom: 132px;
        }

        .system-index {
          margin: 0 0 32px;
          border: 1px solid var(--hairline);
          background: rgba(8, 9, 13, 0.76);
          font-family: var(--font-mono);
        }
        .system-index header,
        .system-index footer {
          display: flex;
          align-items: center;
          justify-content: space-between;
          min-height: 48px;
          padding: 0 18px;
          color: #72717d;
          font-size: 10px;
          letter-spacing: 0.1em;
          text-transform: uppercase;
        }
        .system-index header { border-bottom: 1px solid var(--hairline); }
        .system-index footer { border-top: 1px solid var(--hairline); }
        .system-index header strong { color: #bbb8c2; font-weight: 500; }
        .system-grid { display: grid; grid-template-columns: repeat(3, 1fr); }
        .system-object {
          min-height: 174px;
          padding: 22px 20px;
          border-left: 1px solid var(--hairline);
          border-top: 1px solid var(--hairline);
        }
        .system-object:nth-child(3n + 1) { border-left: 0; }
        .system-object:nth-child(-n + 3) { border-top: 0; }
        .system-object b { color: var(--violet); font: 500 10px/1 var(--font-mono); }
        .system-object h3 { margin: 25px 0 9px; color: #d8d5df; font: 500 15px/1.2 var(--font-mono); }
        .system-object p { color: #74737f; font: 400 12px/1.65 var(--font-mono); }

        .compos-essay {
          padding: 112px 0 150px;
          border-top: 1px solid var(--hairline);
        }
        .compos-essay-head {
          display: grid;
          grid-template-columns: 0.72fr 1.28fr;
          gap: 80px;
          padding-bottom: 72px;
          border-bottom: 1px solid var(--hairline);
        }
        .compos-essay-head c-text,
        .essay-number {
          color: #777683;
          font: 500 10px/1.5 var(--font-mono);
          letter-spacing: 0.1em;
          text-transform: uppercase;
        }
        .compos-essay-head h2 {
          max-width: 850px;
          font: 450 clamp(46px, 5.5vw, 76px)/1.02 var(--font-sans);
          letter-spacing: -0.065em;
        }
        .essay-section {
          display: grid;
          grid-template-columns: 0.72fr 1.28fr;
          gap: 80px;
          padding: 78px 0;
          border-bottom: 1px solid var(--hairline);
        }
        .essay-prose { max-width: 780px; }
        .essay-prose h3 {
          margin-bottom: 30px;
          color: #e4e1d8;
          font: 450 clamp(30px, 3.2vw, 48px)/1.08 var(--font-sans);
          letter-spacing: -0.045em;
        }
        .essay-prose p {
          color: #aaa8b2;
          font: 400 clamp(18px, 1.65vw, 22px)/1.72 var(--font-sans);
          letter-spacing: -0.018em;
        }
        .essay-prose p + p { margin-top: 26px; }
        .essay-prose em { color: #dfdcd3; font-style: normal; }
        .essay-coda {
          max-width: 900px;
          padding-top: 94px;
          color: #dcd9d0;
          font: 450 clamp(32px, 4vw, 58px)/1.15 var(--font-sans);
          letter-spacing: -0.05em;
        }

        .work-surface {
          overflow: hidden;
          border: 1px solid rgba(236, 233, 223, 0.18);
          border-radius: 24px;
          background: rgba(14, 15, 22, 0.91);
          box-shadow: 0 42px 110px rgba(0, 0, 0, 0.55);
          backdrop-filter: blur(24px);
        }
        .work-surface.real-product { border-radius: 0; background: #12131a; }
        .product-screenshot { display: block; width: 100%; height: auto; }



        @keyframes cursor-blink { 50% { opacity: 0; } }









        .home-final { padding: 150px 0 90px; text-align: center; }
        .home-final img { width: 126px; height: 126px; margin-bottom: 28px; border-radius: 30px; }
        .home-final h2 { font-size: clamp(48px, 6vw, 78px); font-weight: 450; letter-spacing: -0.065em; }
        .home-final p { max-width: 580px; margin: 20px auto 32px; color: #8f8e9a; font-size: 18px; }
        .home-final .home-actions { justify-content: center; }

        .home-footer { display: flex; align-items: center; justify-content: space-between; padding: 30px 0 44px; border-top: 1px solid var(--hairline); color: #676672; font-size: 12px; }
        .home-footer strong { color: #aaa9b4; font-weight: 500; }

        @media (max-width: 900px) {
          .home-nav-links a:not(.home-button) { display: none; }
          .home-hero { grid-template-columns: 1fr; padding-top: 68px; text-align: center; }
          .home-hero-copy { display: flex; flex-direction: column; align-items: center; }
          .home-hero-art { min-height: 410px; }
          .home-fractal, .home-orbit { width: min(540px, 92vw); transform: translate(-50%, -50%); }
          .home-fractal { animation: none; }
          .home-proof { margin-top: 0; }
          .compos-essay-head,
          .essay-section { grid-template-columns: 1fr; gap: 30px; }
          .system-grid { grid-template-columns: repeat(2, 1fr); }
          .system-object:nth-child(3n + 1) { border-left: 1px solid var(--hairline); }
          .system-object:nth-child(2n + 1) { border-left: 0; }
          .system-object:nth-child(-n + 3) { border-top: 1px solid var(--hairline); }
          .system-object:nth-child(-n + 2) { border-top: 0; }
        }

        @media (max-width: 620px) {
          .home-shell { width: min(100% - 28px, 1180px); }
          .home-nav { height: 66px; }
          .home-nav .home-button { display: none; }
          .home-hero { min-height: auto; padding-top: 62px; }
          .home-hero h1 { font-size: 56px; }
          .home-hero-art { min-height: 330px; }
          .home-proof { padding-bottom: 90px; }
          .system-grid { grid-template-columns: 1fr; }
          .system-object,
          .system-object:nth-child(3n + 1),
          .system-object:nth-child(2n + 1) { border-left: 0; border-top: 1px solid var(--hairline); }
          .system-object:first-child { border-top: 0; }
          .home-footer { align-items: flex-start; gap: 20px; }
        }

        @media (prefers-reduced-motion: reduce) {
          .home-site *, .home-site *::before, .home-site *::after {
            scroll-behavior: auto !important;
            animation-duration: 0.01ms !important;
            animation-iteration-count: 1 !important;
          }
        }
      </style>

      <c-group class="home-shell">
        <nav class="home-nav" aria-label="Primary navigation">
          <a class="home-brand" href="#top" aria-label={"#{@brand.name} home"}>
            <img
             
              class="compos-logo-image"
              src="/images/compos-logo.png"
              alt=""
            />
            <c-text class="compos-wordmark">compos</c-text>
          </a>
          <c-group class="home-nav-links">
            <a href="#read">Read</a>
            <a href="#write">Write</a>
            <a href="#communicate">Communicate</a>
            <a href="#monitor">Monitor</a>
            <a href="#fix">Fix</a>
          </c-group>
        </nav>

        <section class="home-hero" id="top">
          <c-group class="home-hero-copy">
            <c-group class="home-eyebrow">{@brand.eyebrow}</c-group>
            <h1>
              The <c-text class="compos-aspect">Hackable</c-text> Harness for Power Users.
            </h1>
            <p class="home-hero-subline">It's like Emacs, but it's on the BEAM.</p>
            <p class="home-hero-lede">
              The internet turned work into an interrupt stream. In Compos,
              <strong>the working context is explicit, inspectable, and composed by you.</strong>
              It is a quiet place for thinking, writing, coding, and sustained work.
            </p>
            <c-group class="home-actions">
              <a class="home-button primary" href="#model">Read the system model ↓</a>
              <a class="home-button" href="#workspace">Inspect the workspace ↓</a>
            </c-group>
            <p class="home-hero-note">
              NO FEED · NO NOTIFICATIONS · EXPLICIT CONTEXT · INTERRUPTIBLE MACHINES
            </p>
          </c-group>
          <c-group class="home-hero-art">
            <c-group class="home-orbit"></c-group>
            <img
             
              class="home-fractal"
              src="/images/compos-study-symbolic-composition-v1.png"
              alt="Lambda, branching application, and nested scope compose into a shared center"
            />
            <svg
              :if={false}
              class="home-fractal compos-symbolic-svg"
              viewBox="0 0 800 800"
              role="img"
              aria-label={if @motif == "lambda", do: "Independent fields compose into lambda", else: "Lambda and nested scope compose into an abstract swan"}
            >
              <defs>
                <mask id="compos-mark-mask">
                  <rect width="800" height="800" fill="black" />
                  <path d="M108 525 L255 292 C292 233 300 196 265 170 C244 154 214 151 174 151 L174 95 C249 90 309 109 339 157 C371 208 354 274 310 343 L492 624 L402 624 L263 410 L193 525 Z" fill="white" />
                  <path d="M448 355 C484 313 501 263 501 201 C501 167 522 143 552 143 C582 143 602 166 602 200 C602 253 586 303 559 345 C602 333 647 311 690 280 C713 263 744 270 758 294 C772 320 763 350 737 365 C684 398 625 417 568 420 C601 450 642 472 690 488 C718 497 731 526 721 553 C711 581 682 594 654 582 C584 555 531 517 493 469 Z" fill="white" />
                  <path d="M178 494 C216 442 273 416 337 421 C405 425 460 465 484 527 C508 591 492 657 444 701 C399 742 331 753 269 727 C210 703 172 652 167 590 C164 554 168 522 178 494 Z M252 517 C231 544 226 580 239 611 C255 649 291 672 332 669 C373 666 406 638 416 599 C426 560 410 519 376 497 C335 470 282 478 252 517 Z" fill="white" fill-rule="evenodd" />
                  <path d="M340 405 C386 382 439 385 483 414 C528 444 553 494 550 547 C547 602 516 650 468 674 L430 597 C452 586 467 565 468 540 C470 516 458 493 438 480 C415 465 387 464 364 476 Z" fill="white" />
                </mask>
                <mask id="compos-lambda-input-mask">
                  <rect width="800" height="800" fill="black" />
                  <path d="M61 325 C119 193 273 143 401 282 C342 347 296 431 267 557 C157 554 76 463 61 325 Z" fill="white" />
                  <path d="M739 266 C657 153 508 169 399 282 C462 348 510 433 536 558 C648 536 729 426 739 266 Z" fill="white" />
                  <path d="M143 676 C170 526 268 420 400 376 C532 420 630 526 657 676 C523 716 277 716 143 676 Z" fill="white" />
                  <path d="M226 163 C323 80 490 83 579 174 C520 191 457 221 400 281 C343 222 282 190 226 163 Z" fill="white" />
                </mask>

                <radialGradient id="compos-flow-a" cx="38%" cy="34%" r="72%">
                  <stop offset="0" style="stop-color: var(--mark-cyan)" />
                  <stop offset="0.38" style="stop-color: var(--mark-blue)" />
                  <stop offset="0.75" style="stop-color: var(--mark-violet)" />
                  <stop offset="1" style="stop-color: var(--mark-rose)" />
                </radialGradient>
                <linearGradient id="compos-flow-b" x1="0" y1="0" x2="1" y2="1">
                  <stop offset="0" style="stop-color: var(--mark-ochre)" />
                  <stop offset="0.48" style="stop-color: var(--mark-rose)" />
                  <stop offset="1" style="stop-color: var(--mark-cyan)" />
                </linearGradient>
                <radialGradient id="compos-core" cx="50%" cy="50%" r="50%">
                  <stop offset="0" style="stop-color: var(--mark-ivory)" />
                  <stop offset="0.46" style="stop-color: var(--mark-cyan)" />
                  <stop offset="1" style="stop-color: var(--mark-violet)" />
                </radialGradient>
                <filter id="compos-pigment" x="-8%" y="-8%" width="116%" height="116%" color-interpolation-filters="sRGB">
                  <feTurbulence
                    type="fractalNoise"
                    baseFrequency="0.018 0.42"
                    numOctaves="3"
                    seed="37"
                    result="paper-fiber"
                  />
                  <feTurbulence
                    type="fractalNoise"
                    baseFrequency="0.72"
                    numOctaves="4"
                    seed="19"
                    result="pigment-grain"
                  />
                  <feBlend in="paper-fiber" in2="pigment-grain" mode="multiply" result="surface-noise" />
                  <feColorMatrix
                    in="surface-noise"
                    type="matrix"
                    values="0.9 0 0 0 0.05  0 0.82 0 0 0.04  0 0 0.72 0 0.03  0 0 0 0.34 0"
                    result="toned-noise"
                  />
                  <feComposite in="toned-noise" in2="SourceAlpha" operator="in" result="clipped-noise" />
                  <feBlend in="SourceGraphic" in2="clipped-noise" mode="soft-light" result="textured-color" />
                  <feDisplacementMap
                    in="textured-color"
                    in2="paper-fiber"
                    scale="1.2"
                    xChannelSelector="R"
                    yChannelSelector="G"
                  />
                </filter>
                <filter id="compos-grain-only" x="0" y="0" width="100%" height="100%">
                  <feTurbulence type="fractalNoise" baseFrequency="0.58" numOctaves="4" seed="53" />
                  <feColorMatrix type="saturate" values="0" />
                </filter>
              </defs>

              <g :if={@motif == "swan"}>
              <g class="pigment-surface">
                <g class="mark-base">
                <path d="M108 525 L255 292 C292 233 300 196 265 170 C244 154 214 151 174 151 L174 95 C249 90 309 109 339 157 C371 208 354 274 310 343 L492 624 L402 624 L263 410 L193 525 Z" style="fill: var(--mark-blue)" />
                <path d="M448 355 C484 313 501 263 501 201 C501 167 522 143 552 143 C582 143 602 166 602 200 C602 253 586 303 559 345 C602 333 647 311 690 280 C713 263 744 270 758 294 C772 320 763 350 737 365 C684 398 625 417 568 420 C601 450 642 472 690 488 C718 497 731 526 721 553 C711 581 682 594 654 582 C584 555 531 517 493 469 Z" style="fill: var(--mark-ochre)" />
                <path d="M178 494 C216 442 273 416 337 421 C405 425 460 465 484 527 C508 591 492 657 444 701 C399 742 331 753 269 727 C210 703 172 652 167 590 C164 554 168 522 178 494 Z M252 517 C231 544 226 580 239 611 C255 649 291 672 332 669 C373 666 406 638 416 599 C426 560 410 519 376 497 C335 470 282 478 252 517 Z" style="fill: var(--mark-rose)" fill-rule="evenodd" />
                <path d="M340 405 C386 382 439 385 483 414 C528 444 553 494 550 547 C547 602 516 650 468 674 L430 597 C452 586 467 565 468 540 C470 516 458 493 438 480 C415 465 387 464 364 476 Z" style="fill: var(--mark-violet)" />
                </g>

                <g mask="url(#compos-mark-mask)">
                  <rect class="color-field color-field-a" x="55" y="40" width="690" height="690" fill="url(#compos-flow-a)" />
                  <ellipse class="color-field color-field-b" cx="520" cy="320" rx="280" ry="190" fill="url(#compos-flow-b)" opacity="0.72" />
                  <path class="color-field color-field-c" d="M115 590 C250 300 541 273 738 486 C573 382 356 653 115 590 Z" fill="url(#compos-flow-b)" opacity="0.55" />
                </g>

                <g class="composition-core">
                  <path
                    d="M211 555 C277 447 414 419 543 470 C591 489 626 520 646 558 C576 607 466 630 356 605 C286 590 237 573 211 555 Z"
                    fill="url(#compos-core)"
                    opacity="0.7"
                  />
                  <path
                    d="M277 542 C354 463 466 457 565 516 C493 508 425 535 371 590 C326 579 294 563 277 542 Z"
                    style="fill: var(--mark-violet)"
                    opacity="0.58"
                  />
                  <path
                    d="M444 515 C395 463 377 399 394 331 C408 275 448 228 505 213"
                    fill="none"
                    stroke="var(--mark-ivory)"
                    stroke-width="46"
                    stroke-linecap="round"
                    opacity="0.9"
                  />
                  <ellipse cx="516" cy="211" rx="35" ry="28" style="fill: var(--mark-ivory)" opacity="0.94" />
                  <path d="M544 207 L608 222 L546 238 Z" style="fill: var(--mark-ochre)" opacity="0.86" />
                  <circle cx="524" cy="204" r="5" fill="#07080b" />
                  <path
                    d="M301 537 C369 480 461 477 546 522 C476 519 418 544 371 590 C338 578 314 561 301 537 Z"
                    style="fill: var(--mark-cyan)"
                    opacity="0.34"
                  />
                </g>
              </g>
              <rect
                class="paper-grain"
                width="800"
                height="800"
                mask="url(#compos-mark-mask)"
                filter="url(#compos-grain-only)"
                fill="white"
              />
              <path class="mark-contour" d="M108 525 L255 292 C292 233 300 196 265 170 C244 154 214 151 174 151 M448 355 C501 301 501 252 501 201 M178 494 C216 442 273 416 337 421 C405 425 460 465 484 527" />
              </g>

              <g :if={@motif == "lambda"} class="pigment-surface">
                <g class="mark-base">
                  <path d="M61 325 C119 193 273 143 401 282 C342 347 296 431 267 557 C157 554 76 463 61 325 Z" style="fill: var(--mark-blue)" />
                  <path d="M739 266 C657 153 508 169 399 282 C462 348 510 433 536 558 C648 536 729 426 739 266 Z" style="fill: var(--mark-ochre)" />
                  <path d="M143 676 C170 526 268 420 400 376 C532 420 630 526 657 676 C523 716 277 716 143 676 Z" style="fill: var(--mark-rose)" />
                  <path d="M226 163 C323 80 490 83 579 174 C520 191 457 221 400 281 C343 222 282 190 226 163 Z" style="fill: var(--mark-violet)" />
                </g>
                <g mask="url(#compos-lambda-input-mask)">
                  <rect class="color-field color-field-a" x="38" y="48" width="724" height="680" fill="url(#compos-flow-a)" />
                  <ellipse class="color-field color-field-b" cx="548" cy="310" rx="304" ry="218" fill="url(#compos-flow-b)" opacity="0.74" />
                  <path class="color-field color-field-c" d="M92 631 C235 272 566 265 732 565 C556 408 326 730 92 631 Z" fill="url(#compos-flow-b)" opacity="0.58" />
                </g>
                <circle cx="400" cy="381" r="128" fill="url(#compos-core)" opacity="0.38" />
                <path
                  class="lambda-output"
                  d="M291 583 L383 373 C410 311 409 271 375 239 M383 373 L526 583"
                  fill="none"
                  stroke="var(--mark-ivory)"
                  stroke-width="54"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                />
                <path
                  d="M291 583 L383 373 C410 311 409 271 375 239 M383 373 L526 583"
                  fill="none"
                  stroke="var(--mark-cyan)"
                  stroke-width="18"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  opacity="0.72"
                />
              </g>
              <rect
                :if={@motif == "lambda"}
                class="paper-grain"
                width="800"
                height="800"
                mask="url(#compos-lambda-input-mask)"
                filter="url(#compos-grain-only)"
                fill="white"
              />
            </svg>
            <c-group :if={false} class="motif-dock" aria-label="Compose output form">
              <c-text>Form</c-text>
              <button
                :for={{motif, label} <- [{"lambda", "λ"}, {"swan", "swan"}]}
                type="button"
                class={["motif-button", @motif == motif && "active"]}
                phx-click="set-motif"
                phx-value-motif={motif}
                data-motif={motif}
                aria-label={"Use #{motif} composition"}
                aria-pressed={to_string(@motif == motif)}
              >
                {label}
              </button>
            </c-group>
            <c-group :if={false} class="palette-dock" aria-label="Compose color palette">
              <c-text>Palette</c-text>
              <button
                :for={{palette, color} <- [
                  {"ultraviolet", "#9784ff"},
                  {"phosphor", "#76d39b"},
                  {"ember", "#e69b62"},
                  {"monochrome", "#dad7ce"}
                ]}
                type="button"
                class={["palette-swatch", @palette == palette && "active"]}
                style={"--swatch: #{color}"}
                phx-click="set-palette"
                phx-value-palette={palette}
                data-palette={palette}
                aria-label={"Use #{palette} palette"}
                aria-pressed={to_string(@palette == palette)}
              >
              </button>
            </c-group>
          </c-group>
        </section>

        <section class="system-index" id="model" aria-label="Compos system model">
          <header>
            <strong>System model</strong>
            <c-text>compos://workspace · six primary objects</c-text>
          </header>
          <c-group class="system-grid">
            <article class="system-object">
              <b>01 / BUFFER</b>
              <h3>Material with identity</h3>
              <p>Text, processes, agents, tools, and remote systems appear as addressable buffers.</p>
            </article>
            <article class="system-object">
              <b>02 / VIEW</b>
              <h3>A projection, not a container</h3>
              <p>Multiple views can expose the same live object without copying its state.</p>
            </article>
            <article class="system-object">
              <b>03 / CONTEXT</b>
              <h3>An explicit working set</h3>
              <p>Sources, selections, history, and tools compose into a context you can inspect.</p>
            </article>
            <article class="system-object">
              <b>04 / OPERATION</b>
              <h3>A reversible state transition</h3>
              <p>Commands act in place. Provenance records the actor, input, output, and affected object.</p>
            </article>
            <article class="system-object">
              <b>05 / AGENT</b>
              <h3>The agent comes to the work</h3>
              <p>Machine intelligence enters the chosen context. The work never moves into an agent interface.</p>
            </article>
            <article class="system-object">
              <b>06 / COMPOSITION</b>
              <h3>Objects retain their structure</h3>
              <p>Inputs stay independently navigable while their shared result becomes a new object.</p>
            </article>
          </c-group>
          <footer>
            <c-text>Execution: local process graph</c-text>
            <c-text>Input: keyboard · RPC · agent</c-text>
            <c-text>State: inspectable · persistent · undoable</c-text>
          </footer>
        </section>

        <section class="home-proof" aria-label={"#{@brand.name} product preview"}>
          <c-group class="work-surface real-product">
            <img
              class="product-screenshot"
              src="/images/compos-sentry-workspace.png"
              alt={"#{@brand.name} showing a Sentry issue list with its actions, stack trace, and details beside the work"}
            />
          </c-group>
        </section>
      </c-group>

      <section class="compos-essay" id="workspace">
        <c-group class="home-shell">
          <header class="compos-essay-head">
            <c-text>Design notes / context and attention</c-text>
            <h2>Composing context is a first-class problem for knowledge workers.</h2>
          </header>

          <article class="essay-section">
            <c-text class="essay-number">01 / THE CONDITION</c-text>
            <c-group class="essay-prose">
              <h3>Our tools have mistaken access for understanding.</h3>
              <p>
                A project is a graph of notes, sources, drafts, conversations, queries, programs, and
                decisions. Current software partitions that graph by application, then asks the person doing
                the work to compose its missing context in memory. The browser preserves access to each part,
                but a row of tabs is not a model of how those parts relate. Every switch makes context
                composition an invisible manual task that must finish before the actual work can continue.
              </p>
              <p>
                The same applications share one interrupt surface. Feeds, notifications, messages, and
                background processes compete to define the foreground. They preserve recency, not relevance.
                The result is an enormous implicit context with no stable representation: everything remains
                available, while the structure needed to think about it disappears.
              </p>
              <p>
                Chat-first agents intensify this failure. Their conversation becomes the primary object, so
                the user exports fragments of a project into a prompt, explains relationships the system
                cannot see, and imports the answer back into the work. The agent may be fast, but its context
                is temporary and its operation is opaque. The person is left to reconcile two incomplete
                representations: the project as it exists and the project as the agent briefly understood it.
              </p>
            </c-group>
          </article>

          <article class="essay-section">
            <c-text class="essay-number">02 / THE SYSTEM</c-text>
            <c-group class="essay-prose">
              <h3>Compos makes the working context a first-class object.</h3>
              <p>
                In Compos, a buffer can represent a note, document, query result, process, remote system, or
                agent. Each object keeps its identity, address, history, and native operations. Views project
                related objects into a workspace without copying their content or flattening their structure.
                A composed context records what is present, how it is shown, and which references connect it.
                It can be inspected, saved, resumed, and transformed like any other object.
              </p>
              <p>
                The agent comes to this context. You do not go to the agent. Machine intelligence receives the
                active object, selected references, available tools, and explicit permissions. Its reads and
                writes occur beside the work, where provenance remains visible and execution can be
                interrupted, revised, or undone. The conversation is one useful view of the operation, not a
                replacement for the material on which the operation acts.
              </p>
              <p>
                Composition does not merge every source into one document. The parts remain independently
                addressable while their relations become available for thought and computation. The same model
                can support reading, writing, research, programming, and operations work because its stable
                unit is neither the app nor the chat. It is the context. Input is pulled into that context
                deliberately; arrival does not imply display, and display does not imply interruption. Quiet
                is therefore not a visual theme. It is a property of the system.
              </p>
            </c-group>
          </article>

          <p class="essay-coda">
            Compos is a quiet context graph with programmable views and local agents. It holds the project
            without requiring every part of the project to demand attention at once.
          </p>
        </c-group>
      </section>





      <section class="home-final" id="access">
        <c-group class="home-shell">
          <img
           
            src="/images/compos-study-symbolic-composition-v1.png"
            alt="Lambda, branching application, and nested scope compose into a shared center"
          />
          <h2>A quiet computer for serious work.</h2>
          <p>Active development · local-first runtime · programmable in Scheme · rendered with LiveView.</p>
          <c-group class="home-actions">
            <a class="home-button primary" href={"mailto:#{@brand.email}?subject=#{@brand.name}%20development%20access"}>Request development access</a>
          </c-group>
        </c-group>
      </section>

      <footer class="home-shell home-footer">
        <c-text><strong>{@brand.wordmark}</strong> · {@brand.tagline}</c-text>
        <c-text>compos.in · © 2026 Compos</c-text>
      </footer>
    </main>
    """
  end

  @impl true
  def render(assigns), do: Compos.Ui.Representation.live(__MODULE__, assigns)

end
