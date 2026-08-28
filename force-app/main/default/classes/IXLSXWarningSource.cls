/**
 * Optional companion to IXLSXRowHandler. Row handlers that skip bad data rather than fail the
 * whole row (e.g. an unparseable field value) can implement this so the orchestrator surfaces
 * what got skipped instead of the failure being invisible.
 */
public interface IXLSXWarningSource {
    List<String> getWarnings();
}
