package org.moonfin.androidtv

import android.media.AudioManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioCapabilitiesTrueHdTest {
    private val bitstream = AudioManager.DIRECT_PLAYBACK_BITSTREAM_SUPPORTED

    @Test
    fun `offload only is not TrueHD passthrough`() {
        assertFalse(trueHdBitstreamSupported(true, 0, bitstream))
        assertFalse(trueHdBitstreamSupported(true, 1, bitstream))
        assertFalse(trueHdBitstreamSupported(true, 3, bitstream))
    }

    @Test
    fun `explicit bitstream flag allows TrueHD on an active route`() {
        assertTrue(trueHdBitstreamSupported(true, 4, bitstream))
        assertTrue(trueHdBitstreamSupported(true, 5, bitstream))
    }

    @Test
    fun `inactive bitstream route cannot borrow another device's support`() {
        assertFalse(trueHdBitstreamSupported(false, 4, bitstream))
        assertFalse(trueHdBitstreamSupported(false, 5, bitstream))
    }

    @Test
    fun `7 point 1 48 kHz indicator requires the explicit bitstream flag`() {
        assertEquals("supported", trueHd71ReferenceStatus(true, true, bitstream, bitstream))
        assertEquals("unsupported", trueHd71ReferenceStatus(true, true, 0, bitstream))
        assertEquals("unsupported", trueHd71ReferenceStatus(true, true, 1, bitstream))
        assertEquals("unsupported", trueHd71ReferenceStatus(true, true, 3, bitstream))
        assertEquals("supported", trueHd71ReferenceStatus(true, true, 5, bitstream))
    }

    @Test
    fun `7 point 1 indicator distinguishes unknown and incompatible route`() {
        assertEquals("unknown", trueHd71ReferenceStatus(false, false, null, bitstream))
        assertEquals("unknown", trueHd71ReferenceStatus(true, true, null, bitstream))
        assertEquals("unknown", trueHd71ReferenceStatus(false, true, bitstream, bitstream))
        assertEquals("unsupported", trueHd71ReferenceStatus(true, false, bitstream, bitstream))
    }
}
