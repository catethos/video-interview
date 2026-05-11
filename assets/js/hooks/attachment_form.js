// AttachmentForm — submits the recruiter attachment form via fetch instead
// of a native form post, so a successful upload doesn't navigate away
// from the LiveView. After the controller responds 2xx we push an event
// to the LV, which re-reads the draft and patches the page in place.

const AttachmentForm = {
  mounted() {
    const input = this.el.querySelector('input[type="file"]');
    if (!input) return;

    input.addEventListener("change", async () => {
      const file = input.files && input.files[0];
      if (!file) return;

      const formData = new FormData(this.el);

      try {
        const res = await fetch(this.el.action, {
          method: "POST",
          body: formData,
          headers: { Accept: "application/json" },
        });

        if (res.ok) {
          this.pushEvent("attachment_uploaded", {});
        } else {
          let detail = "upload_failed";
          try {
            const data = await res.json();
            if (data && data.error) detail = data.error;
          } catch (_) {
            // non-JSON body; keep generic error
          }
          this.pushEvent("attachment_error", { error: detail });
        }
      } catch (err) {
        this.pushEvent("attachment_error", { error: String(err) });
      } finally {
        // Reset so picking the same file again still fires `change`.
        input.value = "";
      }
    });
  },
};

export default AttachmentForm;
