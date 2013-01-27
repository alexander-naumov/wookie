;; wookie-plugin-export provides a shared namespace for plugins to provide
;; their public symbols to. apps can :use this package to gain access to
;; the shared plugin namespace.
(defpackage :wookie-plugin-export
  (:use :cl))

(defpackage :wookie-plugin
  (:use :cl :wookie-config :wookie-util :wookie)
  (:export #:register-plugin
           #:set-plugin-request-data
           #:get-plugin-request-data
           #:*plugin-folders*
           #:*enabled-plugins*
           #:load-plugins
           #:unload-plugin
           #:defplugin
           #:defplugfun)
  (:import-from :wookie))
(in-package :wookie-plugin)

(defvar *plugins* (make-hash-table :test #'eq)
  "A hash table holding all registered Wookie plugins.")
(defvar *plugin-asdf* nil
  "A list matching plugin (keyword) names to ASDF systems.")
(defvar *plugin-config* nil
  "A hash table holding configuration values for all plugins.")
(defvar *plugin-folders* (list "./wookie-plugins/"
                               (asdf:system-relative-pathname :wookie #P"wookie-plugins/"))
  "A list of directories where Wookie plugins can be found.")
(defvar *available-plugins* nil
  "A plist (generated by load-plugins) that holds a mapping of plugin <--> ASDF
   systems for the plugins. Reset on each load-plugins run.")

(defun register-plugin (plugin-name init-function unload-function)
  "Register a plugin in the Wookie plugin system. Generally this is called from
   a plugin.lisp file, but can also be called elsewhere in the plugin. The
   plugin-name argument must be a unique keyword, and init-fn is the
   initialization function called that loads the plugin (called only once, on
   register)."
  (wlog +log-debug+ "(plugin) Register plugin ~s~%" plugin-name)
  (let ((plugin-entry (list :name plugin-name
                            :init-function init-function
                            :unload-function unload-function)))
    ;; if enabled, load it
    (when (and (find plugin-name *enabled-plugins*)    ; make sure it's enabled
               (not (gethash plugin-name *plugins*)))  ; make sure it's not loaded already
      (setf (gethash plugin-name *plugins*) plugin-entry)
      (funcall init-function))))

(defun unload-plugin (plugin-name)
  "Unload a plugin from the wookie system. If it's currently registered, its
   unload-function will be called.
   
   Also unloads any current plugins that depend on this plugin. Does this
   recursively so all depencies are always resolved."
  (wlog +log-debug+ "(plugin) Unload plugin ~s~%" plugin-name)
  ;; unload the plugin
  (let ((plugin (gethash plugin-name *plugins*)))
    (when plugin
      (funcall (getf plugin :unload-function (lambda ())))
      (remhash plugin-name *plugins*)))

  (let ((asdf (getf *available-plugins* plugin-name)))
    (when asdf
      (let* ((tmp-deps (asdf:component-depends-on
                            'asdf:load-op
                            (asdf:find-system asdf)))
             (plugin-deps (mapcar (lambda (asdf)
                                    (intern (string asdf) :keyword))
                                  (cdadr tmp-deps)))
             (plugin-systems (loop for system in *available-plugins*
                                   for i from 0
                                   when (oddp i)
                                     collect (intern (string system) :keyword)))
             (to-unload (intersection plugin-deps plugin-systems)))
        (wlog +log-debug+ "(plugin) Unload deps for ~s ~s~%" plugin-name to-unload)
        (dolist (asdf to-unload)
          (let ((plugin-name (getf-reverse *available-plugins* asdf)))
            (unload-plugin plugin-name)))))))

(defun plugin-config (plugin-name)
  "Return the configuration for a plugin. Setfable."
  (unless (hash-table-p *plugin-config*)
    (setf *plugin-config* (make-hash-table :test #'eq)))
  (gethash plugin-name *plugin-config*))

(defun (setf plugin-config) (config plugin-name)
  "Allow setting of plugin configuration via setf."
  (unless (hash-table-p *plugin-config*)
    (setf *plugin-config* (make-hash-table :test #'eq)))
  (setf (gethash plugin-name *plugin-config*) config))

(defun set-plugin-request-data (plugin-name request data)
  "When a plugin wants to store data available to the main app, it can do so by
   storing the data into the request's plugin data. This function allows this by
   taking the plugin-name (keyword), request object passed into the route, and
   the data to store."
  (wlog +log-debug+ "(plugin) Set plugin data ~s: ~a~%" plugin-name data)
  (unless (hash-table-p (request-plugin-data request))
    (setf (request-plugin-data request) (make-hash-table :test #'eq)))
  (setf (gethash plugin-name (request-plugin-data request)) data))

(defun get-plugin-request-data (plugin-name request)
  "Retrieve the data stored into a request object for the plugin-name (keyword)
   plugin."
  (let ((data (request-plugin-data request)))
    (when (hash-table-p data)
      (gethash plugin-name data))))

(defun resolve-dependencies ()
  (let ((systems nil))
    (dolist (enabled *enabled-plugins*)
      (let ((asdf-system (getf *available-plugins* enabled)))
        (when asdf-system
          (wlog +log-debug+ "(plugin) Loading plugin ASDF ~s and deps~%" asdf-system)
          (push asdf-system systems))))
    (let* ((*log-output* *standard-output*)
           (*standard-output* (make-broadcast-stream)))
      (ql:quickload systems :verbose nil :explain nil))))
  
(defun match-plugin-asdf (plugin-name asdf-system)
  "Match a plugin and an ASDF system toeach other."
  (setf (getf *available-plugins* plugin-name) asdf-system))

(defparameter *current-plugin-name* nil
  "Used by load-plugins to tie ASDF systems to a :plugin-name")
  
(defparameter *scanner-plugin-name*
  (cl-ppcre:create-scanner "[/\\\\]([a-z-_]+)[/\\\\]?$" :case-insensitive-mode t)
  "Basically unix's basename in a regex.")

(defun load-plugins ()
  "Load all plugins under the *plugin-folder* fold (set with set-plugin-folder).
   There is also the option to compile the plugins (default nil)."
  (wlog +log-debug+ "(plugin) Load plugins ~s~%" *plugin-folders*)
  (unless *plugins*
    (setf *plugins* (make-hash-table :test #'eq)))
  ;; unload current plugins
  (loop for name being the hash-keys of *plugins* do
    (unload-plugin name))
  (setf *available-plugins* nil)
  (dolist (plugin-folder *plugin-folders*)
    (dolist (dir (cl-fad:list-directory plugin-folder))
      (let* ((dirstr (namestring dir))
             (plugin-name (aref (cadr (multiple-value-list (cl-ppcre:scan-to-strings *scanner-plugin-name* dirstr))) 0))
             (plugin-name (intern (string-upcase plugin-name) :keyword))
             (plugin-defined-p (getf *available-plugins* plugin-name)))
        ;; only load the plugin if a) there's not a plugin <--> ASDF match
        ;; already (meaning the plugin is defined) and b) the plugin dir exists
        (when (and (not plugin-defined-p)
                   (cl-fad:directory-exists-p dir))
          (let ((plugin-file (concatenate 'string dirstr "plugin.asd")))
            (if (cl-fad:file-exists-p plugin-file)
                (progn
                  (wlog +log-debug+ "(plugin) Load ~a~%" plugin-file)
                  (let ((*current-plugin-name* plugin-name))
                    (load plugin-file)))
                (wlog +log-notice+ "(plugin) Missing ~a~%" plugin-file)))))))
  (resolve-dependencies))

(defmacro defplugin (&rest asdf-defsystem-args)
  "Simple wrapper around asdf:defsystem that maps a plugin-name (hopefully in
   *current-plugin-name*) to the ASDF system the plugin defines."
  `(progn
     (asdf:defsystem ,@asdf-defsystem-args)
     (wookie-plugin::match-plugin-asdf wookie-plugin::*current-plugin-name*
                                       ,(intern (string-upcase (string (car asdf-defsystem-args)))
                                                :keyword))))

(defmacro defplugfun (name args &body body)
  "Define a plugin function that is auto-exported to the :wookie-plugin-export
   package."
  `(progn
     (defun ,name ,args ,@body)
     (shadowing-import ',name :wookie-plugin-export)
     (export ',name :wookie-plugin-export)))


