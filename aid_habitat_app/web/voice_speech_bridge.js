(function installAidHabitatSpeechBridge() {
  const originalWebkitRecognition = window.webkitSpeechRecognition;

  function useLocalRecognition(Recognition, locale) {
    function LocalSpeechRecognition() {
      const recognition = new Recognition();
      recognition.lang = locale;
      recognition.processLocally = true;
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
