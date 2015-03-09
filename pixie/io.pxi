(ns pixie.io
  (require pixie.streams :as st :refer :all)
  (require pixie.uv :as uv)
  (require pixie.stacklets :as st))

(defmacro defuvfsfn [nm args return]
  `(defn ~nm ~args
     (let [f (fn [k#]
               (let [cb# (atom nil)]
                 (reset! cb# (ffi-prep-callback uv/uv_fs_cb
                                                (fn [req#]
                                                  (try
                                                    (st/run-and-process k# (~return (pixie.ffi/cast req# uv/uv_fs_t)))
                                                    (uv/uv_fs_req_cleanup req#)
                                                    (-dispose! @cb#)
                                                    (catch e (println e))))))
                 (~(symbol (str "pixie.uv/uv_" (name nm)))
                  (uv/uv_default_loop)
                  (uv/uv_fs_t)
                  ~@args
                  @cb#)))]
       (st/call-cc f))))

(defuvfsfn fs_open [path flags mode] :result)
(defuvfsfn fs_read [file bufs nbufs offset] :result)
(defuvfsfn fs_close [file] :result)


(def DEFAULT-BUFFER-SIZE 1024)

(deftype FileStream [fp offset uvbuf]
  IInputStream
  (read [this buffer len]
    (assert (<= (buffer-capacity buffer) len)
            "Not enough capacity in the buffer")
    (let [_ (pixie.ffi/set! uvbuf :base buffer)
          _ (pixie.ffi/set! uvbuf :len (buffer-capacity buffer))
          read-count (fs_read fp uvbuf 1 offset)]
      (assert (not (neg? read-count)) "Read Error")
      (set-field! this :offset (+ offset read-count))
      (set-buffer-count! buffer read-count)
      read-count))
  (read-byte [this]
    (assert false "Does not support read-byte, wrap in a buffering reader"))
  IClosable
  (close [this]
    (pixie.ffi/free uvbuf)
    (fs_close fp))
  IReduce
  (-reduce [this f init]
    (let [buf (buffer DEFAULT-BUFFER-SIZE)
          rrf (preserving-reduced f)]
      (loop [acc init]
        (let [read-count (read this buf DEFAULT-BUFFER-SIZE)]
          (if (> read-count 0)
            (let [result (reduce rrf acc buf)]
              (if (not (reduced? result))
                (recur result)
                @result))
            acc))))))

(defn open-read
  {:doc "Open a file for reading, returning a IInputStream"
   :added "0.1"}
  [filename]
  (assert (string? filename) "Filename must be a string")
  (->FileStream (fs_open filename uv/O_RDONLY 0) 0 (uv/uv_buf_t)))

(defn read-line
  "Read one line from input-stream for each invocation.
   nil when all lines have been read"
  [input-stream]
  (let [line-feed (into #{} (map int [\newline \return]))
        buf (buffer 1)]
    (loop [acc []]
      (let [len (read input-stream buf 1)]
        (cond
          (and (pos? len) (not (line-feed (first buf))))
          (recur (conj acc (first buf)))

          (and (zero? len) (empty? acc)) nil

          :else (apply str (map char acc)))))))

(defn line-seq
  "Returns the lines of text from input-stream as a lazy sequence of strings.
   input-stream must implement IInputStream"
  [input-stream]
  (when-let [line (read-line input-stream)]
    (cons line (lazy-seq (line-seq input-stream)))))

(deftype FileOutputStream [fp]
  IOutputStream
  (write-byte [this val]
    (assert (integer? val) "Value must be a int")
    (fputc val fp))
  (write [this buffer]
    (fwrite buffer 1 (count buffer) fp))
  IClosable
  (close [this]
    (fclose fp)))

(defn file-output-rf [filename]
  (let [fp (->FileOutputStream (fopen filename "w"))]
    (fn ([] 0)
      ([cnt] (close fp) cnt)
      ([cnt chr]
       (assert (integer? chr))
       (let [written (write-byte fp chr)]
         (if (= written 0)
           (reduced cnt)
           (+ cnt written)))))))


(defn spit [filename val]
  (transduce (map int)
             (file-output-rf filename)
             (str val)))

(defn slurp [filename]
  (let [c (open-read filename)
        result (transduce
                (map char)
                string-builder
                c)]
    (close c)
    result))

(println (slurp "/tmp/a.txt"))

(deftype ProcessInputStream [fp]
  IInputStream
  (read [this buffer len]
    (assert (<= (buffer-capacity buffer) len)
            "Not enough capacity in the buffer")
    (let [read-count (fread buffer 1 len fp)]
      (set-buffer-count! buffer read-count)
      read-count))
  (read-byte [this]
    (fgetc fp))
  IClosable
  (close [this]
    (pclose fp))
  IReduce
  (-reduce [this f init]
    (let [buf (buffer DEFAULT-BUFFER-SIZE)
          rrf (preserving-reduced f)]
      (loop [acc init]
        (let [read-count (read this buf DEFAULT-BUFFER-SIZE)]
          (if (> read-count 0)
            (let [result (reduce rrf acc buf)]
              (if (not (reduced? result))
                (recur result)
                @result))
            acc))))))


(defn popen-read
  {:doc "Open a file for reading, returning a IInputStream"
   :added "0.1"}
  [command]
  (assert (string? command) "Command must be a string")
  (->ProcessInputStream (popen command "r")))


(defn run-command [command]
  (let [c (->ProcessInputStream (popen command "r"))
        result (transduce
                 (map char)
                 string-builder
                 c)]
    (close c)
    result))
