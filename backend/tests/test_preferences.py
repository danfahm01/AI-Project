from httpx import AsyncClient

URL = "/api/v1/users/me/preferences"


async def test_defaults(client: AsyncClient, auth_headers: dict[str, str]) -> None:
    prefs = (await client.get(URL, headers=auth_headers)).json()
    assert prefs["theme"] == "system"
    assert prefs["voice_mode"] == "hands_free"
    assert prefs["auto_speech_detection"] is True
    assert prefs["speaking_rate"] is None
    assert prefs["audio_settings"] == {
        "echo_cancellation": True,
        "noise_suppression": True,
        "auto_gain_control": True,
    }


async def test_partial_update_only_changes_sent_fields(client: AsyncClient, auth_headers: dict[str, str]) -> None:
    await client.patch(URL, json={"language": "id-ID", "voice_name": "alpha"}, headers=auth_headers)
    response = await client.patch(
        URL,
        json={"theme": "dark", "speaking_rate": 1.25, "audio_settings": {"noise_suppression": False}},
        headers=auth_headers,
    )
    assert response.status_code == 200
    prefs = response.json()
    assert prefs["theme"] == "dark"
    assert prefs["speaking_rate"] == 1.25
    assert prefs["language"] == "id-ID"  # untouched
    assert prefs["voice_name"] == "alpha"  # untouched
    assert prefs["audio_settings"]["noise_suppression"] is False
    assert prefs["audio_settings"]["echo_cancellation"] is True


async def test_null_clears_optional_fields(client: AsyncClient, auth_headers: dict[str, str]) -> None:
    await client.patch(URL, json={"voice_name": "alpha", "speaking_rate": 2.0}, headers=auth_headers)
    prefs = (await client.patch(URL, json={"voice_name": None, "speaking_rate": None}, headers=auth_headers)).json()
    assert prefs["voice_name"] is None
    assert prefs["speaking_rate"] is None


async def test_validation(client: AsyncClient, auth_headers: dict[str, str]) -> None:
    for body in (
        {"theme": "neon"},
        {"theme": None},
        {"voice_mode": "telepathy"},
        {"speaking_rate": 10},
        {"language": "not a language"},
        {"unknown_field": 1},
    ):
        response = await client.patch(URL, json=body, headers=auth_headers)
        assert response.status_code == 422, body
