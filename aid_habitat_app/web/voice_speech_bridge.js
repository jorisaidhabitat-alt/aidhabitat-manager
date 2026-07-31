(function installAidHabitatSpeechBridge() {
  const originalWebkitRecognition = window.webkitSpeechRecognition;

  function useLocalRecognition(Recognition, locale) {
    function LocalSpeechRecognition() {
      const recognition = new Recognition();
      recognition.lang = locale;
      recognition.processLocally = true;

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
