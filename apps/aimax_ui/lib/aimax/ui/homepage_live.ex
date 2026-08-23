defmodule Aimax.Ui.HomepageLive do
  use Phoenix.LiveView

  @impl true
  def mount(_params, _session, socket) do
    brand =
      case socket.assigns.live_action do
        :emma ->
          %{
            key: :emma,
            name: "Emma",
            wordmark: "λemma",
            eyebrow: "Emma — the thinking person’s browser",
            email: "hello@emma.space"
          }

        _operad ->
          %{
            key: :operad,
            name: "Operad",
            wordmark: "operad",
            eyebrow: "Operad — the thinking person’s browser",
            email: "hello@operad.work"
          }
      end

    {:ok, assign(socket, brand: brand, page_title: "#{brand.name} — The OS for knowledge work")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="operad-site">
      <style>
        body:has(.operad-site) {
          overflow: auto;
          background: #06070a;
          color: #ece9df;
        }

        .operad-site {
          --void: #06070a;
          --ink: #0b0c12;
          --panel: #11121a;
          --paper: #ece9df;
          --muted: #9897a5;
          --violet: #9784ff;
          --cyan: #71dcff;
          --hairline: rgba(236, 233, 223, 0.13);
          min-height: 100vh;
          overflow: hidden;
          background:
            radial-gradient(circle at 76% 10%, rgba(92, 70, 220, 0.12), transparent 26rem),
            var(--void);
          color: var(--paper);
          font: 400 16px/1.55 var(--font-sans);
        }

        .operad-site a { color: inherit; text-decoration: none; }
        .operad-shell { width: min(1480px, calc(100% - 48px)); margin: 0 auto; }

        .operad-nav {
          position: relative;
          z-index: 10;
          display: flex;
          align-items: center;
          justify-content: space-between;
          height: 76px;
          border-bottom: 1px solid var(--hairline);
        }

        .operad-brand { display: flex; align-items: center; gap: 12px; }
        .operad-brand img { width: 38px; height: 38px; border-radius: 11px; }
        .operad-brand .emma-logo-image { width: 116px; height: auto; border-radius: 0; }
        .operad-brand span { font-size: 20px; font-weight: 500; letter-spacing: -0.04em; }
        .operad-nav-links { display: flex; align-items: center; gap: 30px; color: #aaa9b4; font-size: 14px; }
        .operad-nav-links a { transition: color 160ms ease; }
        .operad-nav-links a:hover { color: var(--paper); }

        .operad-button {
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

        .operad-button:hover { transform: translateY(-2px); border-color: rgba(236, 233, 223, 0.5); }
        .operad-button.primary { border-color: var(--paper); background: var(--paper); color: #101116; }
        .operad-button.primary:hover { background: white; }
        .operad-button.small { min-height: 38px; padding-inline: 17px; }

        .operad-hero {
          position: relative;
          display: grid;
          grid-template-columns: minmax(390px, 0.78fr) minmax(580px, 1.22fr);
          align-items: center;
          min-height: 770px;
          padding: 92px 0 108px;
        }

        .operad-hero-copy { position: relative; z-index: 2; }
        .operad-eyebrow {
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

        .operad-eyebrow::before {
          width: 7px;
          height: 7px;
          border-radius: 50%;
          background: var(--violet);
          box-shadow: 0 0 14px rgba(151, 132, 255, 0.8);
          content: "";
        }

        .operad-hero h1 {
          max-width: 670px;
          font: 450 clamp(58px, 6.6vw, 100px)/0.96 var(--font-sans);
          letter-spacing: -0.075em;
        }

        .operad-hero h1 span {
          display: block;
          background: linear-gradient(100deg, #f5f2e9 12%, #9e99b8 92%);
          -webkit-background-clip: text;
          background-clip: text;
          color: transparent;
        }

        .operad-hero-lede {
          max-width: 610px;
          margin: 32px 0 34px;
          color: #aaa9b4;
          font-size: clamp(18px, 2vw, 21px);
          line-height: 1.55;
          letter-spacing: -0.018em;
        }
        .operad-hero-lede strong { color: #eeebe3; font-weight: 500; }

        .operad-actions { display: flex; flex-wrap: wrap; gap: 12px; }
        .operad-hero-note { max-width: 520px; margin-top: 38px; color: #676672; font: 500 11px/1.8 var(--font-mono); }
        .operad-hero-art { position: relative; min-height: 620px; }
        .operad-orbit {
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

        .operad-orbit::before,
        .operad-orbit::after {
          position: absolute;
          border: 1px solid rgba(236, 233, 223, 0.08);
          border-radius: 50%;
          content: "";
        }

        .operad-orbit::before { inset: 9%; }
        .operad-orbit::after { inset: 22%; border-style: dashed; }
        .operad-fractal {
          position: absolute;
          z-index: 1;
          top: 50%;
          left: 50%;
          width: min(610px, 50vw);
          transform: translate(-43%, -50%);
          mix-blend-mode: screen;
          filter: saturate(0.86) contrast(1.08);
          animation: operad-breathe 10s ease-in-out infinite;
        }

        @keyframes operad-breathe {
          0%, 100% { transform: translate(-43%, -50%) scale(0.985); opacity: 0.9; }
          50% { transform: translate(-43%, -50%) scale(1.015); opacity: 1; }
        }

        .operad-proof {
          position: relative;
          z-index: 3;
          margin-top: 0;
          padding-bottom: 132px;
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
        .capability-band {
          display: grid;
          grid-template-columns: repeat(5, 1fr);
          border-top: 1px solid var(--hairline);
          border-bottom: 1px solid var(--hairline);
        }
        .capability-cell { min-height: 260px; padding: 48px 34px; border-left: 1px solid var(--hairline); }
        .capability-cell:first-child { border-left: 0; }
        .capability-cell h2 { margin-bottom: 22px; font-size: clamp(28px, 2.8vw, 43px); font-weight: 450; letter-spacing: -0.05em; }
        .capability-cell p { color: #868590; font-size: 14px; line-height: 1.7; }

        .surface-topbar {
          display: flex;
          align-items: center;
          gap: 8px;
          height: 48px;
          padding: 0 18px;
          border-bottom: 1px solid var(--hairline);
          color: #888794;
          font-size: 12px;
        }

        .surface-dot { width: 8px; height: 8px; border-radius: 50%; background: #34343f; }
        .surface-title { margin-left: 12px; color: #aaa9b4; }
        .surface-state { margin-left: auto; color: #8f8e9a; }
        .surface-state i {
          display: inline-block;
          width: 6px;
          height: 6px;
          margin-right: 7px;
          border-radius: 50%;
          background: #62d7ad;
        }

        .operad-editor {
          min-height: 610px;
          overflow: hidden;
          background: #101117;
          color: #c9c7d1;
          font: 500 12px/1.62 var(--font-mono);
        }
        .editor-windows { display: grid; grid-template-columns: 62% 38%; min-height: 568px; }
        .editor-window { position: relative; display: flex; min-width: 0; flex-direction: column; }
        .editor-window + .editor-window { border-left: 1px solid #393844; }
        .buffer-body { flex: 1; min-height: 0; padding: 30px 26px 24px 54px; background: #111219; }
        .buffer-body.primary { background: #f0ede4; color: #343239; }
        .buffer-row { display: grid; grid-template-columns: 26px minmax(0, 1fr); gap: 14px; min-height: 20px; }
        .line-number { color: #aaa69c; user-select: none; text-align: right; }
        .buffer-body:not(.primary) .line-number { color: #4f4e5b; }
        .org-meta { color: #8c829d; }
        .org-heading { color: #27242d; font-weight: 650; }
        .org-todo { color: #7762ca; font-weight: 650; }
        .org-link { color: #417d92; text-decoration: underline; text-underline-offset: 3px; }
        .buffer-selection { margin: 3px -8px; padding: 5px 8px; background: #dcd6ee; }
        .cursor-block { display: inline-block; width: 8px; height: 16px; margin-left: 1px; background: #6f59c5; vertical-align: -3px; animation: cursor-blink 1.1s step-end infinite; }
        @keyframes cursor-blink { 50% { opacity: 0; } }

        .context-heading { margin: 0 0 19px; color: #8f83e9; font-size: 10px; letter-spacing: 0.13em; text-transform: uppercase; }
        .context-query { margin-bottom: 22px; color: #e6e3ec; font-size: 15px; line-height: 1.45; }
        .context-source { display: grid; grid-template-columns: 18px 1fr; gap: 9px; padding: 8px 0; border-top: 1px solid #252630; }
        .context-source i { color: #6a5bc1; font-style: normal; }
        .context-source strong { display: block; color: #b9b6c1; font-size: 11px; font-weight: 500; }
        .context-source small { color: #656471; font-size: 9px; }
        .context-trace { margin-top: 23px; padding-left: 13px; border-left: 2px solid #66cbe9; color: #858491; }
        .context-trace b { display: block; margin-bottom: 5px; color: #78d0e8; font-weight: 500; }
        .context-trace em { color: #c9c6d1; font-style: normal; }

        .mode-line { display: flex; align-items: center; gap: 10px; min-height: 27px; padding: 0 10px; background: #d8d4e2; color: #45414d; font-size: 9px; white-space: nowrap; }
        .mode-line.dark { background: #2a2934; color: #aaa7b3; }
        .mode-line .modified { color: #745cc9; }
        .mode-line .position { margin-left: auto; }
        .minibuffer { display: flex; align-items: center; min-height: 42px; padding: 0 15px; border-top: 1px solid #393844; background: #0c0d12; color: #b9b6c1; }
        .minibuffer .prompt { margin-right: 10px; color: #8f83e9; }
        .minibuffer .command { color: #e5e2ea; }
        .minibuffer .hint { margin-left: auto; color: #595864; font-size: 9px; }

        .operad-section { position: relative; padding: 132px 0; border-top: 1px solid var(--hairline); }
        .section-intro { display: grid; grid-template-columns: 0.8fr 1.2fr; gap: 90px; align-items: start; }
        .section-number { color: #666572; font: 500 11px/1 var(--font-mono); letter-spacing: 0.12em; }
        .section-intro h2 { max-width: 760px; font-size: clamp(40px, 5vw, 68px); font-weight: 450; line-height: 1.02; letter-spacing: -0.06em; }
        .section-intro p { max-width: 660px; margin-top: 26px; color: #9695a1; font-size: 18px; }

        .scattered-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; margin-top: 72px; }
        .scattered-card { min-height: 210px; padding: 23px; border: 1px solid var(--hairline); border-radius: 18px; background: rgba(255, 255, 255, 0.018); }
        .scattered-card .card-icon { display: grid; width: 38px; height: 38px; margin-bottom: 48px; place-items: center; border: 1px solid var(--hairline); border-radius: 11px; color: #aaa8b6; }
        .scattered-card strong { display: block; margin-bottom: 8px; font-size: 15px; font-weight: 500; }
        .scattered-card p { color: #777683; font-size: 13px; }

        .workspace-grid { display: grid; grid-template-columns: 1.1fr 0.9fr; gap: 14px; margin-top: 72px; }
        .workspace-card { position: relative; overflow: hidden; min-height: 360px; padding: 34px; border: 1px solid var(--hairline); border-radius: 22px; background: #0e0f15; }
        .workspace-card.wide { grid-row: span 2; min-height: 734px; }
        .workspace-card h3 { margin-bottom: 12px; font-size: 24px; font-weight: 500; letter-spacing: -0.04em; }
        .workspace-card > p { max-width: 460px; color: #858491; font-size: 14px; }

        .source-stack { position: absolute; inset: auto 34px 34px; display: grid; gap: 10px; }
        .source-row { display: grid; grid-template-columns: 36px 1fr auto; align-items: center; gap: 12px; padding: 14px; border: 1px solid var(--hairline); border-radius: 12px; background: #13141c; }
        .source-type { display: grid; width: 36px; height: 36px; place-items: center; border-radius: 9px; background: rgba(151, 132, 255, 0.11); color: #b6aaff; font-size: 11px; }
        .source-row strong { display: block; color: #cac7d1; font-size: 12px; font-weight: 500; }
        .source-row span { color: #6f6e7a; font-size: 10px; }
        .source-row em { color: #61cda9; font-size: 10px; font-style: normal; }

        .decision-list { margin-top: 32px; }
        .decision-item { display: flex; gap: 13px; padding: 14px 0; border-bottom: 1px solid var(--hairline); color: #aaa9b4; font-size: 13px; }
        .decision-item b { color: var(--violet); font-weight: 500; }
        .task-preview { position: absolute; right: -20px; bottom: -18px; width: 76%; padding: 22px; border: 1px solid rgba(113, 220, 255, 0.16); border-radius: 18px 0 0 0; background: #12141c; transform: rotate(-2deg); }
        .task-preview small { color: #6b6b78; text-transform: uppercase; letter-spacing: 0.12em; }
        .task-preview strong { display: block; margin: 13px 0 18px; color: #d8d5df; font-size: 15px; }
        .task-line { height: 7px; margin-top: 10px; border-radius: 99px; background: #22232e; }
        .task-line.short { width: 64%; background: rgba(151, 132, 255, 0.26); }

        .control-band { display: grid; grid-template-columns: 1fr 1fr; gap: 70px; align-items: center; }
        .control-copy h2 { font-size: clamp(42px, 5vw, 68px); font-weight: 450; line-height: 1.02; letter-spacing: -0.06em; }
        .control-copy p { max-width: 540px; margin-top: 24px; color: #93929f; font-size: 18px; }
        .control-panel { padding: 26px; border: 1px solid rgba(151, 132, 255, 0.24); border-radius: 20px; background: radial-gradient(circle at 80% 10%, rgba(151, 132, 255, 0.1), transparent 45%), #101117; }
        .control-panel header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 20px; color: #777683; font-size: 11px; letter-spacing: 0.1em; text-transform: uppercase; }
        .control-panel header i { width: 8px; height: 8px; border-radius: 50%; background: #f0b860; box-shadow: 0 0 12px rgba(240, 184, 96, 0.5); }
        .control-request { padding: 19px; border: 1px solid var(--hairline); border-radius: 14px; background: rgba(0, 0, 0, 0.22); }
        .control-request strong { display: block; margin-bottom: 8px; color: #dbd8e1; font-size: 15px; }
        .control-request p { color: #81808c; font-size: 13px; }
        .control-files { display: flex; gap: 8px; margin: 18px 0; }
        .control-files span { padding: 6px 9px; border-radius: 7px; background: rgba(255, 255, 255, 0.04); color: #898894; font: 500 10px/1 var(--font-mono); }
        .control-actions { display: flex; justify-content: flex-end; gap: 9px; }
        .control-principles { border-top: 1px solid var(--hairline); }
        .principle-row { display: grid; grid-template-columns: 28px 1fr; gap: 18px; padding: 24px 0; border-bottom: 1px solid var(--hairline); }
        .principle-row b { color: #8f83e9; font: 500 11px/1.5 var(--font-mono); }
        .principle-row strong { display: block; margin-bottom: 5px; color: #d8d5df; font-size: 16px; font-weight: 500; }
        .principle-row span { color: #74737f; font-size: 13px; }

        .operad-final { padding: 150px 0 90px; text-align: center; }
        .operad-final img { width: 126px; height: 126px; margin-bottom: 28px; border-radius: 30px; }
        .operad-final .emma-final-logo { width: min(680px, 90vw); height: auto; border-radius: 0; }
        .operad-final h2 { font-size: clamp(48px, 6vw, 78px); font-weight: 450; letter-spacing: -0.065em; }
        .operad-final p { max-width: 580px; margin: 20px auto 32px; color: #8f8e9a; font-size: 18px; }
        .operad-final .operad-actions { justify-content: center; }

        .operad-footer { display: flex; align-items: center; justify-content: space-between; padding: 30px 0 44px; border-top: 1px solid var(--hairline); color: #676672; font-size: 12px; }
        .operad-footer strong { color: #aaa9b4; font-weight: 500; }

        @media (max-width: 900px) {
          .operad-nav-links a:not(.operad-button) { display: none; }
          .operad-hero { grid-template-columns: 1fr; padding-top: 68px; text-align: center; }
          .operad-hero-copy { display: flex; flex-direction: column; align-items: center; }
          .operad-hero-art { min-height: 410px; }
          .operad-fractal, .operad-orbit { width: min(540px, 92vw); transform: translate(-50%, -50%); }
          .operad-fractal { animation: none; }
          .operad-proof { margin-top: 0; }
          .operad-editor { min-height: 560px; }
          .editor-windows { min-height: 518px; grid-template-columns: 58% 42%; }
          .buffer-body { padding-left: 38px; }
          .section-intro, .control-band { grid-template-columns: 1fr; gap: 28px; }
          .scattered-grid { grid-template-columns: repeat(2, 1fr); }
          .workspace-grid { grid-template-columns: 1fr; }
          .workspace-card.wide { min-height: 620px; }
          .capability-band { grid-template-columns: repeat(2, 1fr); }
          .capability-cell:nth-child(odd) { border-left: 0; }
        }

        @media (max-width: 620px) {
          .operad-shell { width: min(100% - 28px, 1180px); }
          .operad-nav { height: 66px; }
          .operad-nav .operad-button { display: none; }
          .operad-hero { min-height: auto; padding-top: 62px; }
          .operad-hero h1 { font-size: 56px; }
          .operad-hero-art { min-height: 330px; }
          .operad-proof { padding-bottom: 90px; }
          .operad-editor { min-height: 720px; font-size: 10px; }
          .editor-windows { display: block; min-height: auto; }
          .editor-window { min-height: 320px; }
          .editor-window + .editor-window { border-top: 1px solid #393844; border-left: 0; }
          .buffer-body { min-height: 293px; padding: 22px 15px 18px 36px; }
          .context-source:nth-of-type(n+5) { display: none; }
          .minibuffer .hint { display: none; }
          .operad-section { padding: 92px 0; }
          .section-intro h2, .control-copy h2 { font-size: 42px; }
          .scattered-grid { grid-template-columns: 1fr; }
          .scattered-card { min-height: 170px; }
          .scattered-card .card-icon { margin-bottom: 32px; }
          .workspace-card { min-height: 330px; padding: 26px; }
          .workspace-card.wide { min-height: 590px; }
          .source-stack { inset: auto 20px 20px; }
          .control-band { gap: 44px; }
          .operad-footer { align-items: flex-start; gap: 20px; }
          .capability-band { grid-template-columns: 1fr; }
          .capability-cell { min-height: 190px; border-left: 0; border-top: 1px solid var(--hairline); }
          .capability-cell:first-child { border-top: 0; }
        }

        @media (prefers-reduced-motion: reduce) {
          .operad-site *, .operad-site *::before, .operad-site *::after {
            scroll-behavior: auto !important;
            animation-duration: 0.01ms !important;
            animation-iteration-count: 1 !important;
          }
        }
      </style>

      <div class="operad-shell">
        <nav class="operad-nav" aria-label="Primary navigation">
          <a class="operad-brand" href="#top" aria-label={"#{@brand.name} home"}>
            <img :if={@brand.key == :operad} src="/images/operad-fractal-512.png" alt="" />
            <span :if={@brand.key == :operad}>operad</span>
            <img
              :if={@brand.key == :emma}
              class="emma-logo-image"
              src="/images/emma-logo-v1.png"
              alt="λemma"
            />
          </a>
          <div class="operad-nav-links">
            <a href="#read">Read</a>
            <a href="#write">Write</a>
            <a href="#communicate">Communicate</a>
            <a href="#monitor">Monitor</a>
            <a href="#fix">Fix</a>
          </div>
        </nav>

        <section class="operad-hero" id="top">
          <div class="operad-hero-copy">
            <div class="operad-eyebrow">{@brand.eyebrow}</div>
            <h1>The OS for <span>knowledge work.</span></h1>
            <p class="operad-hero-lede">
              Bring your documents, conversations, research, tools, and AI into one connected workspace.
              Everything stays within arm’s reach.
            </p>
            <div class="operad-actions">
              <a class="operad-button primary" href="#access">Get early access</a>
              <a class="operad-button" href="#workspace">See how it works ↓</a>
            </div>
            <p class="operad-hero-note">
              Not a chat window. {@brand.name} holds the live material of every app you work in.
            </p>
          </div>
          <div class="operad-hero-art">
            <div class="operad-orbit"></div>
            <img class="operad-fractal" src="/images/operad-fractal-master.png" alt="" aria-hidden="true" />
          </div>
        </section>

        <section class="operad-proof" aria-label={"#{@brand.name} product preview"}>
          <div class="work-surface real-product">
            <img
              class="product-screenshot"
              src="/images/operad-sentry-workspace.png"
              alt={"#{@brand.name} showing a Sentry issue list with its actions, stack trace, and details beside the work"}
            />
          </div>
        </section>
      </div>

      <section class="capability-band" aria-label={"#{@brand.name} capabilities"}>
        <article class="capability-cell" id="read">
          <h2>Read.</h2>
          <p>Newsletters, papers, threads, and reports become text you can mark up.</p>
        </article>
        <article class="capability-cell" id="write">
          <h2>Write.</h2>
          <p>Compose across live sources. Keep citations attached to every sentence.</p>
        </article>
        <article class="capability-cell" id="communicate">
          <h2>Communicate.</h2>
          <p>Reply, assign, and record the decision where the evidence already lives.</p>
        </article>
        <article class="capability-cell" id="monitor">
          <h2>Monitor.</h2>
          <p>Keep errors, deploys, projects, and queues beside the work they affect.</p>
        </article>
        <article class="capability-cell" id="fix">
          <h2>Fix.</h2>
          <p>Hand an issue to an agent. Inspect the change, then approve or undo it.</p>
        </article>
      </section>

      <section class="operad-section" id="why">
        <div class="operad-shell">
          <div class="section-intro">
            <span class="section-number">01 — THE PROBLEM</span>
            <div>
              <h2>Your work is scattered beyond reach.</h2>
              <p>
                Knowledge work now spans too many tabs, tools, and agents. {@brand.name} gathers it into
                one navigable information space without hiding what happens.
              </p>
            </div>
          </div>
          <div class="scattered-grid">
            <div class="scattered-card">
              <div class="card-icon">↗</div><strong>Every source</strong>
              <p>Open the evidence behind the current work with one command.</p>
            </div>
            <div class="scattered-card">
              <div class="card-icon">◎</div><strong>Every tool</strong>
              <p>Bring the systems you use into the same live workspace.</p>
            </div>
            <div class="scattered-card">
              <div class="card-icon">Δ</div><strong>Every agent</strong>
              <p>Machine intelligence shares the material already in front of you.</p>
            </div>
            <div class="scattered-card">
              <div class="card-icon">⌘</div><strong>Every action</strong>
              <p>Inspect, run, or reverse the next step without leaving the work.</p>
            </div>
          </div>
        </div>
      </section>

      <section class="operad-section" id="workspace">
        <div class="operad-shell">
          <div class="section-intro">
            <span class="section-number">02 — THE WORKSPACE</span>
            <div>
              <h2>The right thing appears beside the work.</h2>
              <p>
                Open a source, inspect a detail, ask an agent, or run an action without changing context.
              </p>
            </div>
          </div>
          <div class="workspace-grid">
            <div class="workspace-card wide">
              <h3>Every source becomes a place you can enter.</h3>
              <p>Browse the material behind an answer. Move between evidence and work without leaving the workspace.</p>
              <div class="source-stack">
                <div class="source-row">
                  <div class="source-type">PDF</div><div><strong>Regional outlook 2026</strong><span>Market research · page 42</span></div><em>Relevant</em>
                </div>
                <div class="source-row">
                  <div class="source-type">MTG</div><div><strong>Customer interview: Acme</strong><span>Conversation · 28 minutes</span></div><em>Quoted</em>
                </div>
                <div class="source-row">
                  <div class="source-type">DOC</div><div><strong>Expansion assumptions</strong><span>Working draft · revised yesterday</span></div><em>Current</em>
                </div>
                <div class="source-row">
                  <div class="source-type">WEB</div><div><strong>Local pricing benchmarks</strong><span>Research · 6 sources</span></div><em>Verified</em>
                </div>
              </div>
            </div>
            <div class="workspace-card">
              <h3>The machine leaves a trail.</h3>
              <p>See what it read, what it changed, and which decisions shaped the result.</p>
              <div class="decision-list">
                <div class="decision-item"><b>01</b><span>Start with one regional market.</span></div>
                <div class="decision-item"><b>02</b><span>Test pricing before hiring.</span></div>
                <div class="decision-item"><b>03</b><span>Review the plan in September.</span></div>
              </div>
            </div>
            <div class="workspace-card">
              <h3>Thought becomes work in place.</h3>
              <p>Research becomes a brief, plan, or finished draft inside the same information space.</p>
              <div class="task-preview">
                <small>Next action</small>
                <strong>Prepare the launch recommendation</strong>
                <div class="task-line"></div><div class="task-line short"></div>
              </div>
            </div>
          </div>
        </div>
      </section>

      <section class="operad-section">
        <div class="operad-shell control-band">
          <div class="control-copy">
            <span class="section-number">03 — YOUR CONTROL</span>
            <h2 style="margin-top: 25px">Reach for a command, not another app.</h2>
            <p>
              {@brand.name} brings the next source, tool, or action to your current position. Your work
              stays visible while the workspace changes around it.
            </p>
          </div>
          <div class="control-principles">
            <div class="principle-row">
              <b>01</b><div><strong>It reads in the open.</strong><span>Every source stays one command away.</span></div>
            </div>
            <div class="principle-row">
              <b>02</b><div><strong>It writes in place.</strong><span>Changes appear where the work already lives.</span></div>
            </div>
            <div class="principle-row">
              <b>03</b><div><strong>You can interrupt.</strong><span>Inspect, redirect, or take over at any moment.</span></div>
            </div>
          </div>
        </div>
      </section>

      <section class="operad-final" id="access">
        <div class="operad-shell">
          <img :if={@brand.key == :operad} src="/images/operad-fractal-512.png" alt="Operad recursive emblem" />
          <img
            :if={@brand.key == :emma}
            class="emma-final-logo"
            src="/images/emma-logo-v1.png"
            alt="λemma"
          />
          <h2>Your whole working world. Within reach.</h2>
          <p>The OS for knowledge work.</p>
          <div class="operad-actions">
            <a class="operad-button primary" href={"mailto:#{@brand.email}?subject=#{@brand.name}%20early%20access"}>Get early access</a>
          </div>
        </div>
      </section>

      <footer class="operad-shell operad-footer">
        <span><strong>{@brand.wordmark}</strong> · The OS for knowledge work</span>
        <span>© 2026 {@brand.name}</span>
      </footer>
    </main>
    """
  end
end
