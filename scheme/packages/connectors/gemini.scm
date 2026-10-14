;;; gemini.scm --- the Gemini CLI as an ACP connector.
;;;
;;; @google/gemini-cli speaks ACP behind --experimental-acp. This package
;;; declares everything about the agent: how to run it, how to install it,
;;; its key, and the Google sign-in that works instead of the key. Setup
;;; reads these declarations; nothing else lists them.

(domain! 'chat)
(effects! '(write))

(defcustom 'gemini-api-key #f
  "The Gemini API key the Gemini CLI uses."
  'type 'secret 'group 'gemini 'env "GEMINI_API_KEY"
  'key-page "https://aistudio.google.com/apikey")

(define-connector! "gemini"
  '(cmd "gemini --experimental-acp" model-flag "-m "
    description "Gemini CLI — Google account or Gemini API key"
    ;; the CLI drops _meta, so our prompt sections ride the first turn
    system-in-prompt #t
    env (("GEMINI_API_KEY" gemini-api-key))
    install (("gemini" "npm install -g @google/gemini-cli"))
    signin "gemini"
    ;; the model family it serves: -m passes an id the CLI does not list yet
    accepts "^(gemini-|auto$)"
    ;; a Google sign-in through `gemini` itself answers for the key
    signin-files (".gemini/oauth_creds.json")))

(provide 'connector-gemini)
