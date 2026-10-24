// Hands the Open WebUI "Voice mode" button to the native call (AC8).
// Injected at document start in the main frame. Anything not positively identified is left alone,
// so the web page keeps its own behaviour (e.g. after an Open WebUI redesign).
//
// Target (Open WebUI v0.12.2, src/lib/components/chat/MessageInput.svelte): the round black
// button next to the input with aria-label $i18n.t('Voice mode') / $i18n.t('Return to call').
// Never the dictation button (#voice-input-button) or the send button (#send-message-button).
(() => {
  // aria-label in every locale shipped with v0.12.2 (generated from src/lib/i18n/locales).
  const LABELS = new Set([
    "Ahots-modua",
    "Aramaya dön",
    "Askar n taɣect",
    "Atgriezties zvanā",
    "Balik sa tawag",
    "Balso režimas",
    "Balss režīms",
    "Bumalik sa tawag",
    "Chế độ giọng nói",
    "Far aftur til uppkallið",
    "Fill ar an nglao",
    "Glasovni način",
    "Glasovni način rada",
    "Grįžti į skambutį",
    "Gå tilbake til samtalen",
    "Hangmód",
    "Hlasový režim",
    "Häälrežiim",
    "Itzuli deira",
    "Jaňa dolan",
    "Kembali ke panggilan",
    "Mod Gutha",
    "Mod Suara",
    "Mod vocal",
    "Modalità vocale",
    "Mode de veu",
    "Mode sa tingog",
    "Mode suara",
    "Mode vocal",
    "Modo de Voz",
    "Modo de voz",
    "Naase kõnesse",
    "Ovoz rejimi",
    "Palaa puheluun",
    "Puhetila",
    "Quay lại cuộc gọi",
    "Return to call",
    "Return to such call",
    "Revenir à l'appel",
    "Revino la apel",
    "Röstläge",
    "Røddarháttur",
    "Ses tertibi",
    "Sesli mod",
    "Spraakmodus",
    "Sprachmodus",
    "Stemmetilstand",
    "Such voice mode",
    "Səs rejimi",
    "Talemodus",
    "Terug naar gesprek",
    "Tillbaka till samtalet",
    "Torna alla chiamata",
    "Tornar a la trucada",
    "Tryb głosowy",
    "Uɣal ɣer usiwel",
    "Vend tilbage til opkaldet",
    "Vissza a híváshoz",
    "Voice mode",
    "Voltar à chamada",
    "Volver a la llamada",
    "Volver á chamada",
    "Vrati se na poziv",
    "Vrati se u poziv",
    "Vrni se v klic",
    "Vrátiť sa k hovoru",
    "Wróć do rozmowy",
    "Zpět k hovoru",
    "Zurück zum Anruf",
    "Zəngə qayıt",
    "Επιστροφή στην κλήση",
    "Λειτουργία Φωνής",
    "Вернуться к звонку",
    "Врати се у позив",
    "Връщане към обаждането",
    "Гласов режим",
    "Гласовни режим",
    "Голосовий режим",
    "Овоз режими",
    "Повернутися до виклику",
    "Режим голоса",
    "חזור לשיחה",
    "מצב קולי",
    "ئاۋاز ھالىتى",
    "العودة إلى المكالمة",
    "الوضع الصوتي",
    "بازگشت به تماس",
    "حالت صوتی",
    "وائس موڈ",
    "چاقىرىشقا قايتىش",
    "کال پر واپس جائیں",
    "कॉल पर लौटें",
    "वॉइस मोड",
    "কলে ফিরে যান",
    "ভয়েস মোড",
    "ਆਵਾਜ਼ ਮੋਡ",
    "ਕਾਲ 'ਤੇ ਵਾਪਸ ਜਾਓ",
    "அழைப்பிற்குத் திரும்பவும்",
    "குரல் முறை",
    "กลับไปยังการโทร",
    "โหมดเสียง",
    "སྐད་འབོད་ལ་ཕྱིར་ལོག",
    "སྐད་སྒྲའི་རྣམ་པ།",
    "ზარში დაბრუნება",
    "ხმის რეჟიმი",
    "語音模式",
    "语音模式",
    "返回通話",
    "返回通话",
    "通話に戻る",
    "音声モード",
    "음성 모드 사용",
    "통화로 돌아가기"
  ]);
  const EXCLUDED = new Set(['voice-input-button', 'send-message-button']);

  const isVoiceButton = (button) => {
    if (!button || button.tagName !== 'BUTTON' || button.type !== 'button') return false;
    if (EXCLUDED.has(button.id)) return false;
    // Must belong to the chat input form.
    const form = button.closest('form');
    if (!form || !form.querySelector('#chat-input, textarea')) return false;
    const label = (button.getAttribute('aria-label') || '').trim();
    if (LABELS.has(label)) return true;
    // Structural fallback for an unlisted locale: the round black icon-only button with a label.
    const cls = button.classList;
    return !button.id && !!label && cls.contains('rounded-full') && cls.contains('bg-black')
      && button.children.length === 1 && button.firstElementChild.tagName.toLowerCase() === 'svg';
  };

  const selectedModels = () => {
    try {
      const models = JSON.parse(sessionStorage.getItem('selectedModels') || '[]');
      return Array.isArray(models) ? models.filter((m) => typeof m === 'string' && m) : [];
    } catch (_) {
      return [];
    }
  };

  const chatId = () => {
    const match = location.pathname.match(/\/c\/([^/?#]+)/);
    return match ? decodeURIComponent(match[1]) : null;
  };

  const handler = (event) => {
    const enabled = window.__owuiNativeVoice !== false;
    if (!enabled || !window.webkit?.messageHandlers?.owuiVoice) return;
    const button = event.target instanceof Element ? event.target.closest('button') : null;
    if (!isVoiceButton(button)) return;
    // Keep other listeners (tooltips, the page's own handler) out of every phase of the tap, but only
    // cancel the click: preventDefault on touchstart / pointerdown would suppress the click itself.
    event.stopImmediatePropagation();
    if (event.type !== 'click') return;
    event.preventDefault();
    window.webkit.messageHandlers.owuiVoice.postMessage({
      chatId: chatId(),
      models: selectedModels(),
      label: button.getAttribute('aria-label') || '',
    });
  };

  for (const type of ['pointerdown', 'mousedown', 'touchstart', 'click']) {
    document.addEventListener(type, handler, { capture: true, passive: false });
  }
  // Exposed for tests.
  window.__owuiIsVoiceButton = isVoiceButton;
})();
