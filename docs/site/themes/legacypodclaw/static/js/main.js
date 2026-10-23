(function () {
  // status bar clock shows the visitor's local time, like the device would
  var clock = document.querySelector('[data-clock]');
  function tick() {
    var d = new Date();
    var m = d.getMinutes();
    clock.textContent = d.getHours() + ':' + (m < 10 ? '0' : '') + m;
  }
  if (clock) {
    tick();
    setInterval(tick, 30000);
  }

  // code wells can scroll sideways, so keyboard users must be able to focus them
  var pres = document.querySelectorAll('pre');
  for (var i = 0; i < pres.length; i++) {
    if (pres[i].scrollWidth > pres[i].clientWidth) pres[i].setAttribute('tabindex', '0');
  }

  // the tab bar "more" button opens the sidebar as a sheet on small screens
  var sheet = document.getElementById('sidebar');
  var opener = document.querySelector('[data-sheet-open]');
  var closer = document.querySelector('[data-sheet-close]');
  if (!sheet || !opener) return;

  function setOpen(open) {
    sheet.classList.toggle('sidebar--open', open);
    document.body.classList.toggle('sheet-open', open);
    opener.setAttribute('aria-expanded', open ? 'true' : 'false');
    if (open) {
      var first = sheet.querySelector('a, button');
      if (first) first.focus();
    } else {
      opener.focus();
    }
  }
  opener.addEventListener('click', function () {
    setOpen(!sheet.classList.contains('sidebar--open'));
  });
  if (closer) closer.addEventListener('click', function () { setOpen(false); });
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape' && sheet.classList.contains('sidebar--open')) setOpen(false);
  });
})();
