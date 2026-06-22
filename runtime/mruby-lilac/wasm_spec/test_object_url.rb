Spec.describe "Lilac.create_object_url / revoke_object_url" do
  Spec.assert "create_object_url returns a usable object URL string" do
    url = Lilac.create_object_url("WEBVTT\n\n", type: "text/vtt")
    Spec.assert_true url.is_a?(String)
    # createObjectURL produces a blob: URL.
    Spec.assert_true url.start_with?("blob:")
    Lilac.revoke_object_url(url)
  end

  Spec.assert "accepts an Array of Blob parts" do
    url = Lilac.create_object_url(["a", "b"], type: "text/plain")
    Spec.assert_true url.start_with?("blob:")
    Lilac.revoke_object_url(url)
  end

  Spec.assert "works without a type" do
    url = Lilac.create_object_url("data")
    Spec.assert_true url.start_with?("blob:")
    Lilac.revoke_object_url(url)
  end

  Spec.assert "revoke_object_url is a no-op on nil" do
    # Must not raise.
    Lilac.revoke_object_url(nil)
    Spec.assert_equal true, true
  end
end
