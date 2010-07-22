(custom-set-variables
 '(case-fold-search t) ;search non-case-sensitive
 '(current-language-environment "utf-8")
 '(default-input-method "rfc1345")
 '(global-font-lock-mode t nil (font-lock)) ; color
 '(visible-bell t) ; no beeps
 '(column-number-mode t) ;show column number at the bottom
 '(transient-mark-mode t) ;selection visible
 '(kill-ring-max 20) ;more yanks
 '(show-paren-mode t nil (paren)) ;hilight matching parenthesis
 '(tool-bar-mode 0) ;no toolbar/menubar
 '(menu-bar-mode 0)
 '(make-backup-files nil)) ;no backup files~
(set-language-environment 'utf-8)
(set-terminal-coding-system 'utf-8)
(set-keyboard-coding-system 'utf-8)
(set-language-environment 'utf-8)
(prefer-coding-system 'utf-8)
(fset 'yes-or-no-p 'y-or-n-p)

;; better buffer management
(require 'iswitchb)
(iswitchb-default-keybindings)

;;C-x g allows one to reach a line with its number 
(global-set-key "\C-xg" 'goto-line) 
