const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

if (!reducedMotion.matches && "IntersectionObserver" in window) {
  const sections = document.querySelectorAll(".content-section");
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting || entry.boundingClientRect.top < 0) {
          entry.target.classList.add("section-visible");
          observer.unobserve(entry.target);
        }
      }
    },
    { rootMargin: "0px 0px -25% 0px", threshold: 0 }
  );

  for (const section of sections) {
    for (const [index, element] of [...section.children].entries()) {
      element.classList.add("section-reveal");
      element.style.setProperty("--reveal-delay", `${Math.min(index * 70, 280)}ms`);
    }
    observer.observe(section);
  }
}
