;; VibroSense - Decentralized Seismic Activity Monitoring Network
;; An advanced ground motion detection system for tremors, vibrations, and seismic events

;; Constants
(define-constant SEISMIC-COORDINATOR tx-sender)
(define-constant ERR-ACCESS-RESTRICTED (err u700))
(define-constant ERR-SEISMOMETER-PRESENT (err u701))
(define-constant ERR-SEISMOMETER-ABSENT (err u702))
(define-constant ERR-AMPLITUDE-INVALID (err u703))
(define-constant ERR-RECORD-AGED (err u704))
(define-constant ERR-COMMITMENT-LOW (err u705))
(define-constant ERR-SEISMOMETER-PAUSED (err u706))
(define-constant ERR-SURGE-ABNORMAL (err u707))
(define-constant ERR-REGION-UNRECOGNIZED (err u708))
(define-constant ERR-SENSITIVITY-INVALID (err u709))

;; Minimum commitment required to become a seismometer (in microSTX)
(define-constant MIN-SEISMOMETER-COMMITMENT u1000000) ;; 1 STX

;; Maximum age for seismic records (in blocks)
(define-constant MAX-RECORD-AGE u144) ;; ~24 hours

;; Maximum allowed amplitude surge percentage (basis points)
(define-constant MAX-SURGE u2000) ;; 20%

;; Maximum sensitivity digits allowed
(define-constant MAX-SENSITIVITY u18)

;; Maximum amplitude value (to prevent overflow)
(define-constant MAX-AMPLITUDE-VALUE u340282366920938463463374607431768211455) ;; uint max

;; Data Variables
(define-data-var grid-operational bool true)
(define-data-var total-seismometers uint u0)
(define-data-var lead-seismologist (optional principal) none)

;; Whitelist of tracked regions
(define-map tracked-regions (string-ascii 32) bool)

;; Data Maps
;; Seismometer registry
(define-map seismometers
    principal
    {
        is-recording: bool,
        commitment-amount: uint,
        fidelity-score: uint,
        total-detections: uint,
        last-detection-height: uint
    }
)

;; Seismic detections for different regions
(define-map seismic-detections
    (string-ascii 32) ;; region code
    {
        amplitude: uint,
        sensitivity: uint,
        last-detected: uint,
        detection-frequency: uint,
        seismometer: principal
    }
)

;; Correlated seismic patterns
(define-map correlated-patterns
    (string-ascii 32) ;; region code
    {
        median-amplitude: uint,
        average-amplitude: uint,
        min-amplitude: uint,
        max-amplitude: uint,
        sensitivity: uint,
        last-correlation: uint,
        detection-cluster: uint,
        validity-index: uint
    }
)

;; Detection logs for correlation
(define-map detection-logs
    {region: (string-ascii 32), seismometer: principal}
    {
        amplitude: uint,
        timestamp: uint,
        processed: bool
    }
)

;; Seismometer commitments
(define-map seismometer-commitments
    principal
    uint
)

;; Input validation functions

;; Validate region code - only alphanumeric characters allowed
(define-read-only (is-valid-region (region (string-ascii 32)))
    (let (
        (region-length (len region))
    )
    (and
        (> region-length u0)
        (<= region-length u32)
        ;; Check if region is in tracked list (if whitelist is being used)
        (default-to true (map-get? tracked-regions region))
    ))
)

;; Validate sensitivity parameter
(define-read-only (is-valid-sensitivity (sensitivity uint))
    (and
        (>= sensitivity u0)
        (<= sensitivity MAX-SENSITIVITY)
    )
)

;; Validate amplitude parameter
(define-read-only (is-valid-amplitude (amplitude uint))
    (and
        (> amplitude u0)
        (<= amplitude MAX-AMPLITUDE-VALUE)
    )
)

;; Read-only functions

;; Get seismometer information
(define-read-only (get-seismometer-info (seismometer principal))
    (map-get? seismometers seismometer)
)

;; Get seismic detection for a region
(define-read-only (get-seismic-detection (region (string-ascii 32)))
    (if (is-valid-region region)
        (map-get? seismic-detections region)
        none
    )
)

;; Get correlated patterns for a region
(define-read-only (get-correlated-patterns (region (string-ascii 32)))
    (if (is-valid-region region)
        (map-get? correlated-patterns region)
        none
    )
)

;; Get latest correlation with age verification
(define-read-only (get-latest-correlation (region (string-ascii 32)))
    (if (is-valid-region region)
        (match (map-get? correlated-patterns region)
            correlation-data 
            (if (> (- stacks-block-height (get last-correlation correlation-data)) MAX-RECORD-AGE)
                (err ERR-RECORD-AGED)
                (ok {
                    amplitude: (get median-amplitude correlation-data),
                    sensitivity: (get sensitivity correlation-data),
                    timestamp: (get last-correlation correlation-data),
                    validity: (get validity-index correlation-data)
                })
            )
            (err ERR-SEISMOMETER-ABSENT)
        )
        (err ERR-REGION-UNRECOGNIZED)
    )
)

;; Check if grid is operational
(define-read-only (is-grid-operational)
    (var-get grid-operational)
)

;; Get total number of seismometers
(define-read-only (get-total-seismometers)
    (var-get total-seismometers)
)

;; Check if seismometer is recording and has sufficient commitment
(define-read-only (is-valid-seismometer (seismometer principal))
    (match (map-get? seismometers seismometer)
        seismometer-data
        (and 
            (get is-recording seismometer-data)
            (>= (get commitment-amount seismometer-data) MIN-SEISMOMETER-COMMITMENT)
        )
        false
    )
)

;; Calculate amplitude surge between two detections
(define-read-only (calculate-surge (amplitude1 uint) (amplitude2 uint))
    (let (
        (higher (if (> amplitude1 amplitude2) amplitude1 amplitude2))
        (lower (if (> amplitude1 amplitude2) amplitude2 amplitude1))
        (diff (- higher lower))
        (surge (* (/ diff lower) u10000))
    )
    surge)
)

;; Admin functions

;; Add region to tracked list (only seismic coordinator)
(define-public (add-tracked-region (region (string-ascii 32)))
    (begin
        (asserts! (is-eq tx-sender SEISMIC-COORDINATOR) ERR-ACCESS-RESTRICTED)
        (asserts! (> (len region) u0) ERR-REGION-UNRECOGNIZED)
        (map-set tracked-regions region true)
        (ok true)
    )
)

;; Remove region from tracked list (only seismic coordinator)
(define-public (remove-tracked-region (region (string-ascii 32)))
    (begin
        (asserts! (is-eq tx-sender SEISMIC-COORDINATOR) ERR-ACCESS-RESTRICTED)
        (map-delete tracked-regions region)
        (ok true)
    )
)

;; Public functions

;; Register as a seismometer
(define-public (register-seismometer)
    (let (
        (seismometer tx-sender)
        (commitment-amount (stx-get-balance tx-sender))
    )
    (asserts! (var-get grid-operational) ERR-ACCESS-RESTRICTED)
    (asserts! (is-none (map-get? seismometers seismometer)) ERR-SEISMOMETER-PRESENT)
    (asserts! (>= commitment-amount MIN-SEISMOMETER-COMMITMENT) ERR-COMMITMENT-LOW)
    
    ;; Transfer commitment to contract
    (try! (stx-transfer? MIN-SEISMOMETER-COMMITMENT tx-sender (as-contract tx-sender)))
    
    ;; Register seismometer
    (map-set seismometers seismometer {
        is-recording: true,
        commitment-amount: MIN-SEISMOMETER-COMMITMENT,
        fidelity-score: u100,
        total-detections: u0,
        last-detection-height: stacks-block-height
    })
    
    ;; Track commitment
    (map-set seismometer-commitments seismometer MIN-SEISMOMETER-COMMITMENT)
    
    ;; Update total seismometers
    (var-set total-seismometers (+ (var-get total-seismometers) u1))
    
    (ok true))
)

;; Deregister seismometer
(define-public (deregister-seismometer)
    (let (
        (seismometer tx-sender)
        (seismometer-data (unwrap! (map-get? seismometers seismometer) ERR-SEISMOMETER-ABSENT))
        (commitment (get commitment-amount seismometer-data))
    )
    (asserts! (var-get grid-operational) ERR-ACCESS-RESTRICTED)
    (asserts! (get is-recording seismometer-data) ERR-SEISMOMETER-PAUSED)
    
    ;; Stop recording
    (map-set seismometers seismometer (merge seismometer-data {is-recording: false}))
    
    ;; Return commitment
    (try! (as-contract (stx-transfer? commitment tx-sender seismometer)))
    
    ;; Remove commitment tracking
    (map-delete seismometer-commitments seismometer)
    
    ;; Update total seismometers
    (var-set total-seismometers (- (var-get total-seismometers) u1))
    
    (ok true))
)

;; Submit seismic detection with comprehensive input validation
(define-public (submit-detection (region (string-ascii 32)) (amplitude uint) (sensitivity uint))
    (let (
        (seismometer tx-sender)
        (seismometer-data (unwrap! (map-get? seismometers seismometer) ERR-SEISMOMETER-ABSENT))
    )
    ;; Comprehensive input validation
    (asserts! (var-get grid-operational) ERR-ACCESS-RESTRICTED)
    (asserts! (get is-recording seismometer-data) ERR-SEISMOMETER-PAUSED)
    (asserts! (is-valid-region region) ERR-REGION-UNRECOGNIZED)
    (asserts! (is-valid-amplitude amplitude) ERR-AMPLITUDE-INVALID)
    (asserts! (is-valid-sensitivity sensitivity) ERR-SENSITIVITY-INVALID)
    
    ;; Check for reasonable amplitude surge if previous detection exists
    (match (map-get? seismic-detections region)
        existing-detection
        (let ((surge (calculate-surge amplitude (get amplitude existing-detection))))
            (asserts! (<= surge MAX-SURGE) ERR-SURGE-ABNORMAL)
        )
        true ;; No existing detection, allow any amplitude
    )
    
    ;; Update seismic detection with validated inputs
    (map-set seismic-detections region {
        amplitude: amplitude,
        sensitivity: sensitivity,
        last-detected: stacks-block-height,
        detection-frequency: (match (map-get? seismic-detections region)
            existing (+ (get detection-frequency existing) u1)
            u1
        ),
        seismometer: seismometer
    })
    
    ;; Record detection for correlation with validated inputs
    (map-set detection-logs {region: region, seismometer: seismometer} {
        amplitude: amplitude,
        timestamp: stacks-block-height,
        processed: false
    })
    
    ;; Update seismometer stats
    (map-set seismometers seismometer (merge seismometer-data {
        total-detections: (+ (get total-detections seismometer-data) u1),
        last-detection-height: stacks-block-height
    }))
    
    (ok true))
)