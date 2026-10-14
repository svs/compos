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
    ;; a Google sign-in through `gemini` itself answers for the key
    signin-files (".gemini/oauth_creds.json")
    models ("auto" "gemini-4-argon" "gemini-3.1-pro-preview" "gemini-3.8-flash"
            "gemini-3-flash-preview")))

(provide 'connector-gemini)
