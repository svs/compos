;;; full-browser-test.scm --- interactive web buffers, without a network.

(domain! 'testing)
(effects! '(write))

(deftest 'a-full-browser-page-is-an-interactive-restorable-buffer
  "the mode keeps the URL and rebuilds its browser view"
  (lambda ()
    (let ((here (current-buffer))
          (buf (full-browser "session.test/account")))
      (check-equal! (buffer-local buf 'browser-url)
                    "https://session.test/account" "the normalized URL")
      (check-equal! (buffer-local buf 'browser-src-url)
                    "https://session.test/account" "the iframe URL")
      (check-equal! (buffer-local buf 'header-line) #f "the page uses the full window")
      (check-equal! (buffer-local buf 'render-mode) "browser" "the browser renderer")
      (check-equal! (buffer-local buf 'browser-page-mode)
                    "raw-mode" "a new live page starts raw")
      (check-equal! (buffer-local buf 'group) "browser" "the browser group")
      (check-true! (buffer-read-only? buf) "the backing buffer is read-only")

      ;; A desktop restore calls the setup function again. The durable URL
      ;; remains, while the setup function rebuilds render policy and keys.
      (buffer-set-local! buf 'render-mode #f)
      (with-current-buffer buf (lambda () (set-mode! "full-browser-mode")))
      (check-equal! (buffer-local buf 'render-mode) "browser" "the view returns")
      (check-equal! (buffer-local buf 'browser-url)
                    "https://session.test/account" "the URL remains")
      (full-browser-location! (active-window)
                              "https://session.test/profile" "Your profile")
      (check-equal! (buffer-local buf 'browser-url)
                    "https://session.test/profile" "reported navigation updates the URL")
      (check-equal! (buffer-local buf 'browser-src-url)
                    "https://session.test/account" "reported navigation does not reload")
      (switch-to-buffer! here)
      (buffer-kill! buf))))

(deftest 'a-full-browser-url-reuses-its-buffer-and-navigation-stays-in-place
  "browser tabs follow the reader buffer policy"
  (lambda ()
    (let ((here (current-buffer))
          (first (full-browser "https://session.test/one")))
      (switch-to-buffer! here)
      (check-equal! (full-browser "https://session.test/one") first
                    "the same URL reuses its buffer")
      (check-equal! (full-browser "https://session.test/two") first
                    "navigation inside the buffer stays in place")
      (check-equal! (buffer-local first 'browser-url)
                    "https://session.test/two" "the address changes")
      (switch-to-buffer! here)
      (buffer-kill! first))))

(deftest 'apropos-finds-the-interactive-browser-entry
  "the full browser is discoverable beside the reading browser"
  (lambda ()
    (let ((hits (value->string (apropos "interactive web page"))))
      (check-contains! hits "full-browser" "the command is in the catalog")
      (check-contains! hits "host browser profile" "the session behavior is documented"))))

(deftest 'development-server-addresses-default-to-http
  "a local port opens without requiring a scheme"
  (lambda ()
    (check-equal! (full-browser--normalize "localhost:3000")
                  "http://localhost:3000" "a localhost port")
    (check-equal! (full-browser--normalize "127.0.0.1:5173/app")
                  "http://127.0.0.1:5173/app" "an IPv4 development server")
    (check-equal! (full-browser--normalize "[::1]:4000")
                  "http://[::1]:4000" "an IPv6 development server")))

(deftest 'page-handling-progresses-and-returns-to-the-paired-live-page
  "raw and theme share the iframe; readable uses the existing reader"
  (lambda ()
    (let ((saved-fetch *web-fetch*)
          (saved-visited (or (read-file *web-visited-file*) ""))
          (here (current-buffer))
          (live (full-browser "https://progressive.test/article")))
      (theme-mode)
      (check-equal! (current-buffer) live "theme stays in the live buffer")
      (check-equal! (buffer-local live 'browser-page-mode)
                    "theme-mode" "theme changes only page handling")
      (set! *web-fetch*
        (lambda (url k) (k "# Article\n\nReadable body.")))
      (let ((reader (readable-mode)))
        (check-equal! (buffer-local reader 'mode-name)
                      "browse-mode" "readable reuses the text reader")
        (check-equal! (buffer-local reader 'browser-page-mode)
                      "readable-mode" "the reader records its page handling")
        (check-equal! (raw-mode) live
                      "raw returns to the paired live buffer")
        (check-equal! (buffer-local live 'browser-page-mode)
                      "raw-mode" "raw removes the theme")
        (buffer-kill! reader))
      (set! *web-fetch* saved-fetch)
      (write-file! *web-visited-file* saved-visited)
      (switch-to-buffer! here)
      (buffer-kill! live))))
