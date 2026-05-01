;; Emacs init file: Sunit Joshi

;; Start the server
(server-start)

;; UI Improvements
(setq inhibit-startup-screen t)  ; Disable splash screen
(menu-bar-mode -1)               ; Disable menu bar
(tool-bar-mode -1)               ; Disable tool bar
(scroll-bar-mode -1)             ; Disable scroll bar
(desktop-save-mode 1)
(xterm-mouse-mode 1)
(fido-vertical-mode t)
(electric-pair-mode 1)

(setq backup-directory-alist '(("." . "~/.emacs.d/backups")))
(setq desktop-path '("~/.emacs.d/backups"))
(desktop-save-mode 1)


;; Initialize packages (for Emacs 27+)
(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org") t)

(use-package markdown-mode :ensure t)

(add-hook 'text-mode-hook #'visual-line-mode)                                                                             
(add-hook 'markdown-mode-hook #'visual-line-mode)

(load-theme 'dracula t)

;; Highlight color
(custom-set-faces                                                                                                         
 '(region ((t (:background "#44475a" :extend t)))))


;; Useful commands
;; CtrX-u: Undo, Alt-W: Copies marked txt
;; Ctr-X-Backspace: Backward kill sentence
;; CtrX-CtrW: File save as
;; Alt-Space: Deletes all spaces & tab around the cursorOB
;; Ctr-X o : Move to other buffer

;;Set backup folder
(setq backup-directory-alist '(("." . "~/.emacs.d/backups/")))
(setq auto-save-file-name-transforms
      `((".*" "~/.emacs.d/backups/" t)))

(defun move-line-up ()
  "Move the current line up."
  (interactive)
  (transpose-lines 1)
  (forward-line -2))

(defun move-line-down ()
  "Move the current line down."
  (interactive)
  (forward-line 1)
  (transpose-lines 1)
  (forward-line -1))

(global-set-key (kbd "M-<up>") 'move-line-up)
(global-set-key (kbd "M-<down>") 'move-line-down)

(global-set-key (kbd "C-_") 'undo)

(global-display-line-numbers-mode)

;; select current line
(defun select-current-line ()                                                                         
  "Select the entire current line."                                                                                       
  (interactive)
  (beginning-of-line)                                                                                                     
  (push-mark (line-end-position) t t))                                                                

(global-set-key (kbd "C-c l") 'select-current-line)


;; Comment region
(global-set-key (kbd "C-c ;") 'comment-or-uncomment-region)


;; format current buffer
(defun format-current-buffer ()                                                                                           
  "Re-indent the entire buffer."                                                                      
  (interactive)                                                                                                           
  (indent-region (point-min) (point-max)))

(global-set-key (kbd "C-c f") 'format-current-buffer)

;;format file hook
(add-hook 'emacs-lisp-mode-hook
	  (lambda ()
	    (add-hook 'before-save-hook 'indent-region-or-buffer nil t)))


(defun indent-region-or-buffer ()            
  "Indent the entire buffer."
  (indent-region (point-min) (point-max)))


;; Save on frame close and server kill                                                                                    
(add-hook 'kill-emacs-hook #'desktop-save-in-desktop-dir)                                                                 
(add-hook 'delete-frame-functions (lambda (_) (desktop-save-in-desktop-dir)))                         

;; Switch to last real buffer when emacsclient connects
(add-hook 'server-after-make-frame-hook                                                                                   
          (lambda ()                                                                                                      
            (let ((buf (cl-find-if (lambda (b)
                                     (not (string-prefix-p "*" (buffer-name b))))                                         
                                   (buffer-list))))                                                   
              (when buf (switch-to-buffer buf)))))

