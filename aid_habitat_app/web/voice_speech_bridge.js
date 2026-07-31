(function installAidHabitatSpeechBridge() {
  const originalWebkitRecognition = window.webkitSpeechRecognition;

  function useLocalRecognition(Recognition, locale) {
    function LocalSpeechRecognition() {
      const recognition = new Recognition();
      recognition.lang = locale;
      recognition.processLocally = true;
      const nativeStart = recognition.start.bind(recognition);
      const nativeStop = recognition.stop.bind(recognition);
      const nativeAbort = recognition.abort.bind(recognition);
      let microphoneStream = null;
      let startCancelled = false;

      const releaseMicrophone = function() {
        if (!microphoneStream) return;
        microphoneStream.getTracks().forEach(function(track) {
          track.stop();
        });
        microphoneStream = null;
      };

      // Keep only event names and error codes for troubleshooting. Never
      // retain recognized words or microphone data in this diagnostic log.
      window.__aidHabitatSpeechEvents = [];
      const record = function(event) {
        const detail = event && event.error ? ':' + event.error : '';
        window.__aidHabitatSpeechEvents.push(event.type + detail);
        window.__aidHabitatSpeechEvents =
          window.__aidHabitatSpeechEvents.slice(-30);
      };
      [
        'start',
        'audiostart',
        'soundstart',
        'speechstart',
        'result',
        'speechend',
        'soundend',
        'audioend',
        'error',
        'end',
      ].forEach(function(type) {
        recognition.addEventListener(type, record);
      });

      recognition.addEventListener('end', releaseMicrophone);
      recognition.start = function(audioTrack) {
        if (audioTrack) {
          nativeStart(audioTrack);
          return;
        }

        startCancelled = false;
        navigator.mediaDevices.getUserMedia({
          audio: {
            echoCancellation: true,
            noiseSuppression: true,
            autoGainControl: true,
          },
        }).then(function(stream) {
          if (startCancelled) {
            stream.getTracks().forEach(function(track) {
              track.stop();
            });
            return;
          }

          const track = stream.getAudioTracks()[0];
          if (!track) throw new Error('No live audio track');
          microphoneStream = stream;
          if ('contentHint' in track) {
            track.contentHint = 'speech-recognition';
          }
          window.__aidHabitatSpeechInput = track.label || 'microphone';
          nativeStart(track);
        }).catch(function(error) {
          window.__aidHabitatSpeechEvents.push(
            'microphone-error:' + (error.name || 'unknown')
          );
          releaseMicrophone();
          // Preserve the browser's normal microphone fallback when explicit
          // audio-track recognition is unavailable.
          nativeStart();
        });
      };
      recognition.stop = function() {
        startCancelled = true;
        try {
          nativeStop();
        } finally {
          releaseMicrophone();
        }
      };
      recognition.abort = function() {
        startCancelled = true;
        try {
          nativeAbort();
        } finally {
          releaseMicrophone();
        }
      };
      return recognition;
    }

    LocalSpeechRecognition.prototype = Recognition.prototype;
    Object.defineProperty(window, 'webkitSpeechRecognition', {
      configurable: true,
      writable: true,
      value: LocalSpeechRecognition,
    });
  }

  window.aidHabitatPrepareSpeechRecognition = async function(locale) {
    const Recognition = window.SpeechRecognition || originalWebkitRecognition;
    if (!Recognition) {
      window.__aidHabitatSpeechRuntime = 'unsupported';
      return 'unsupported';
    }

    // Browsers without the on-device API keep their existing remote service.
    if (typeof Recognition.available !== 'function' ||
        typeof Recognition.install !== 'function') {
      window.__aidHabitatSpeechRuntime = 'remote';
      return 'remote';
    }

    const options = {
      langs: [locale],
      processLocally: true,
    };

    try {
      let availability = await Recognition.available(options);
      if (availability === 'downloadable' || availability === 'downloading') {
        const installed = await Recognition.install(options);
        if (!installed) {
          window.__aidHabitatSpeechRuntime = 'install-failed';
          return 'install-failed';
        }
        availability = await Recognition.available(options);
      }

      if (availability !== 'available') {
        window.__aidHabitatSpeechRuntime = 'remote';
        return 'remote';
      }
      useLocalRecognition(Recognition, locale);
      window.__aidHabitatSpeechRuntime = 'local';
      return 'local';
    } catch (error) {
      console.warn('[voice] local recognition preparation failed', error);
      window.__aidHabitatSpeechRuntime = 'local-error';
      return 'local-error';
    }
  };
})();
