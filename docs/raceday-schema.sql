/* ============================================================================
   RaceDay — Road Event Management System
   Programming 2B — Portfolio of Evidence, Part 1, Section C
   Student: Nqobani Ngwenya (ST10457588)

   Target platform : Microsoft SQL Server 2019 or later. Run in SQL Server
                     Management Studio 19+ (see README section 2.2)
   Purpose         : Creates the complete RaceDay schema and seeds it with
                     realistic South African sample data.
   Run order       : Execute this script as a single batch on a clean instance.
                     It is re-runnable: existing RaceDay objects are dropped
                     first, so the script can be executed repeatedly during
                     development without manual clean-up.

   Contents
     1.  Database creation
     2.  Drop existing objects (safe re-run)
     3.  Lookup tables            : Roles
     4.  Identity tables          : Users, ParticipantProfiles
     5.  Event tables             : Events, EventCategories, EventRoutes,
                                    EventMedia
     6.  Participation tables     : Enrolments, Results
     7.  Indexes
     8.  Seed data
     9.  Verification queries
   ========================================================================== */


/* ============================================================================
   1. DATABASE CREATION
   ========================================================================== */
IF DB_ID(N'RaceDayDb') IS NULL
BEGIN
    CREATE DATABASE RaceDayDb;
END;
GO

USE RaceDayDb;
GO

SET NOCOUNT ON;
GO


/* ============================================================================
   2. DROP EXISTING OBJECTS
   Tables are dropped in reverse dependency order so that foreign keys never
   block the drop. This makes the script safe to re-run.
   ========================================================================== */
IF OBJECT_ID(N'dbo.Results', N'U')            IS NOT NULL DROP TABLE dbo.Results;
IF OBJECT_ID(N'dbo.Enrolments', N'U')         IS NOT NULL DROP TABLE dbo.Enrolments;
IF OBJECT_ID(N'dbo.EventMedia', N'U')         IS NOT NULL DROP TABLE dbo.EventMedia;
IF OBJECT_ID(N'dbo.EventRoutes', N'U')        IS NOT NULL DROP TABLE dbo.EventRoutes;
IF OBJECT_ID(N'dbo.EventCategories', N'U')    IS NOT NULL DROP TABLE dbo.EventCategories;
IF OBJECT_ID(N'dbo.Events', N'U')             IS NOT NULL DROP TABLE dbo.Events;
IF OBJECT_ID(N'dbo.ParticipantProfiles', N'U')IS NOT NULL DROP TABLE dbo.ParticipantProfiles;
IF OBJECT_ID(N'dbo.Users', N'U')              IS NOT NULL DROP TABLE dbo.Users;
IF OBJECT_ID(N'dbo.Roles', N'U')              IS NOT NULL DROP TABLE dbo.Roles;
GO


/* ============================================================================
   3. LOOKUP TABLES
   ========================================================================== */

/* Roles ---------------------------------------------------------------------
   The two roles required by the brief are seeded in section 8. Roles are held
   in their own table (rather than as a string column on Users) so that the
   API can authorise against a stable RoleId and so that a third role can be
   added later without a schema change.                                       */
CREATE TABLE dbo.Roles
(
    RoleId          INT             IDENTITY(1,1)   NOT NULL,
    RoleName        NVARCHAR(20)                    NOT NULL,
    Description     NVARCHAR(200)                   NULL,
    CONSTRAINT PK_Roles           PRIMARY KEY (RoleId),
    CONSTRAINT UQ_Roles_RoleName  UNIQUE      (RoleName),
    CONSTRAINT CK_Roles_RoleName  CHECK       (RoleName IN (N'Organiser', N'Participant'))
);
GO


/* ============================================================================
   4. IDENTITY TABLES
   ========================================================================== */

/* Users ---------------------------------------------------------------------
   One table holds both roles. RoleId decides what the account may do. The
   password is stored as a hash plus a per-user salt; the plain-text password
   is never stored. The seed data in section 8 uses clearly marked placeholder
   hashes, which Part 2 replaces with real BCrypt output.                     */
CREATE TABLE dbo.Users
(
    UserId          INT             IDENTITY(1,1)   NOT NULL,
    RoleId          INT                             NOT NULL,
    FirstName       NVARCHAR(60)                    NOT NULL,
    LastName        NVARCHAR(60)                    NOT NULL,
    Email           NVARCHAR(160)                   NOT NULL,
    PasswordHash    NVARCHAR(256)                   NOT NULL,
    PasswordSalt    NVARCHAR(128)                   NOT NULL,
    PhoneNumber     NVARCHAR(20)                    NULL,
    DateOfBirth     DATE                            NULL,
    Gender          NVARCHAR(10)                    NULL,
    Province        NVARCHAR(40)                    NULL,
    IsActive        BIT                             NOT NULL CONSTRAINT DF_Users_IsActive   DEFAULT (1),
    CreatedAt       DATETIME2(0)                    NOT NULL CONSTRAINT DF_Users_CreatedAt  DEFAULT (SYSUTCDATETIME()),
    LastLoginAt     DATETIME2(0)                    NULL,
    CONSTRAINT PK_Users            PRIMARY KEY (UserId),
    CONSTRAINT UQ_Users_Email      UNIQUE      (Email),
    CONSTRAINT FK_Users_Roles      FOREIGN KEY (RoleId) REFERENCES dbo.Roles (RoleId),
    CONSTRAINT CK_Users_Email      CHECK       (Email LIKE N'%_@_%._%'),
    CONSTRAINT CK_Users_Gender     CHECK       (Gender IS NULL OR Gender IN (N'Male', N'Female', N'Other')),
    CONSTRAINT CK_Users_DOB        CHECK       (DateOfBirth IS NULL OR DateOfBirth > '1900-01-01')
);
GO


/* ParticipantProfiles -------------------------------------------------------
   Race-day information that only applies to participants: emergency contact,
   club, t-shirt size and medical aid. Kept out of Users so that organiser
   rows are not padded with columns that can never apply to them.
   One profile per participant, enforced by a UNIQUE constraint on UserId,
   which is what makes this a one-to-one relationship.                        */
CREATE TABLE dbo.ParticipantProfiles
(
    ProfileId               INT             IDENTITY(1,1)   NOT NULL,
    UserId                  INT                             NOT NULL,
    ClubName                NVARCHAR(100)                   NULL,
    AthleticsNumber         NVARCHAR(30)                    NULL,
    TshirtSize              NVARCHAR(6)                     NULL,
    EmergencyContactName    NVARCHAR(120)                   NOT NULL,
    EmergencyContactPhone   NVARCHAR(20)                    NOT NULL,
    MedicalAidScheme        NVARCHAR(80)                    NULL,
    MedicalNotes            NVARCHAR(400)                   NULL,
    UpdatedAt               DATETIME2(0)                    NOT NULL CONSTRAINT DF_Profiles_UpdatedAt DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_ParticipantProfiles         PRIMARY KEY (ProfileId),
    CONSTRAINT UQ_ParticipantProfiles_UserId  UNIQUE     (UserId),
    CONSTRAINT FK_ParticipantProfiles_Users   FOREIGN KEY (UserId) REFERENCES dbo.Users (UserId) ON DELETE CASCADE,
    CONSTRAINT CK_ParticipantProfiles_Tshirt  CHECK      (TshirtSize IS NULL OR TshirtSize IN (N'XS', N'S', N'M', N'L', N'XL', N'XXL', N'3XL'))
);
GO


/* ============================================================================
   5. EVENT TABLES
   ========================================================================== */

/* Events --------------------------------------------------------------------
   Owned by exactly one organiser (OrganiserId -> Users.UserId). Latitude and
   longitude are stored so that Part 3 can call a weather API for the venue on
   race day. Slug gives the MVC application a clean, unique URL segment.      */
CREATE TABLE dbo.Events
(
    EventId                 INT             IDENTITY(1,1)   NOT NULL,
    OrganiserId             INT                             NOT NULL,
    EventName               NVARCHAR(140)                   NOT NULL,
    Slug                    NVARCHAR(160)                   NOT NULL,
    Discipline              NVARCHAR(20)                    NOT NULL,
    Description             NVARCHAR(2000)                  NULL,
    EventDate               DATE                            NOT NULL,
    StartTime               TIME(0)                         NOT NULL,
    VenueName               NVARCHAR(140)                   NOT NULL,
    StreetAddress           NVARCHAR(200)                   NULL,
    City                    NVARCHAR(80)                    NOT NULL,
    Province                NVARCHAR(40)                    NOT NULL,
    Latitude                DECIMAL(9,6)                    NULL,
    Longitude               DECIMAL(9,6)                    NULL,
    RegistrationOpensAt     DATETIME2(0)                    NOT NULL,
    RegistrationClosesAt    DATETIME2(0)                    NOT NULL,
    Status                  NVARCHAR(20)                    NOT NULL CONSTRAINT DF_Events_Status    DEFAULT (N'Draft'),
    IsLicensed              BIT                             NOT NULL CONSTRAINT DF_Events_Licensed  DEFAULT (0),
    CreatedAt               DATETIME2(0)                    NOT NULL CONSTRAINT DF_Events_CreatedAt DEFAULT (SYSUTCDATETIME()),
    UpdatedAt               DATETIME2(0)                    NULL,
    CONSTRAINT PK_Events                 PRIMARY KEY (EventId),
    CONSTRAINT UQ_Events_Slug            UNIQUE      (Slug),
    CONSTRAINT FK_Events_Organiser       FOREIGN KEY (OrganiserId) REFERENCES dbo.Users (UserId),
    CONSTRAINT CK_Events_Discipline      CHECK (Discipline IN (N'Running', N'Walking', N'Cycling', N'Trail', N'Triathlon')),
    CONSTRAINT CK_Events_Status          CHECK (Status IN (N'Draft', N'Published', N'RegistrationClosed', N'Completed', N'Cancelled')),
    CONSTRAINT CK_Events_Province        CHECK (Province IN (N'Eastern Cape', N'Free State', N'Gauteng', N'KwaZulu-Natal',
                                                            N'Limpopo', N'Mpumalanga', N'Northern Cape', N'North West', N'Western Cape')),
    CONSTRAINT CK_Events_RegWindow       CHECK (RegistrationClosesAt > RegistrationOpensAt),
    CONSTRAINT CK_Events_Latitude        CHECK (Latitude IS NULL OR Latitude BETWEEN -90 AND 90),
    CONSTRAINT CK_Events_Longitude       CHECK (Longitude IS NULL OR Longitude BETWEEN -180 AND 180)
);
GO


/* EventCategories -----------------------------------------------------------
   The distance options inside an event: for example 21.1km, 10km and a 5km
   walk. A participant always enters a category, never an event directly,
   which is why Enrolments points here.                                       */
CREATE TABLE dbo.EventCategories
(
    CategoryId          INT             IDENTITY(1,1)   NOT NULL,
    EventId             INT                             NOT NULL,
    CategoryName        NVARCHAR(80)                    NOT NULL,
    DistanceKm          DECIMAL(6,2)                    NOT NULL,
    EntryFee            DECIMAL(8,2)                    NOT NULL,
    ParticipantLimit    INT                             NULL,
    MinimumAge          INT                             NOT NULL CONSTRAINT DF_Categories_MinAge DEFAULT (0),
    StartTime           TIME(0)                         NULL,
    CutOffMinutes       INT                             NULL,
    IsTimed             BIT                             NOT NULL CONSTRAINT DF_Categories_IsTimed DEFAULT (1),
    CONSTRAINT PK_EventCategories            PRIMARY KEY (CategoryId),
    CONSTRAINT UQ_EventCategories_NamePerEvent UNIQUE   (EventId, CategoryName),
    /* Needed as the target of the composite foreign key on Enrolments, which
       is what stops an enrolment pointing at a category that belongs to a
       different event. */
    CONSTRAINT UQ_EventCategories_EventCategory UNIQUE  (EventId, CategoryId),
    CONSTRAINT FK_EventCategories_Events     FOREIGN KEY (EventId) REFERENCES dbo.Events (EventId) ON DELETE CASCADE,
    CONSTRAINT CK_EventCategories_Distance   CHECK (DistanceKm > 0),
    CONSTRAINT CK_EventCategories_Fee        CHECK (EntryFee >= 0),
    CONSTRAINT CK_EventCategories_Limit      CHECK (ParticipantLimit IS NULL OR ParticipantLimit > 0),
    CONSTRAINT CK_EventCategories_MinAge     CHECK (MinimumAge BETWEEN 0 AND 100),
    CONSTRAINT CK_EventCategories_CutOff     CHECK (CutOffMinutes IS NULL OR CutOffMinutes > 0)
);
GO


/* EventRoutes ---------------------------------------------------------------
   Route detail per category, supporting the route information feature in
   Part 3. The GPX file itself lives in Azure Blob Storage; only the blob URL
   is stored here.                                                            */
CREATE TABLE dbo.EventRoutes
(
    RouteId             INT             IDENTITY(1,1)   NOT NULL,
    CategoryId          INT                             NOT NULL,
    RouteName           NVARCHAR(120)                   NOT NULL,
    TerrainType         NVARCHAR(30)                    NOT NULL,
    ElevationGainM      INT                             NULL,
    WaterPointCount     INT                             NULL,
    GpxBlobUrl          NVARCHAR(400)                   NULL,
    RouteNotes          NVARCHAR(600)                   NULL,
    CONSTRAINT PK_EventRoutes                PRIMARY KEY (RouteId),
    CONSTRAINT FK_EventRoutes_Categories     FOREIGN KEY (CategoryId) REFERENCES dbo.EventCategories (CategoryId) ON DELETE CASCADE,
    CONSTRAINT CK_EventRoutes_Terrain        CHECK (TerrainType IN (N'Road', N'Trail', N'Mixed', N'Track', N'Promenade')),
    CONSTRAINT CK_EventRoutes_Elevation      CHECK (ElevationGainM IS NULL OR ElevationGainM >= 0),
    CONSTRAINT CK_EventRoutes_WaterPoints    CHECK (WaterPointCount IS NULL OR WaterPointCount >= 0)
);
GO


/* EventMedia ----------------------------------------------------------------
   Images and documents attached to an event. Files are uploaded to Azure Blob
   Storage in Part 3; the database keeps the URL, the type and the audit
   trail of who uploaded it.                                                  */
CREATE TABLE dbo.EventMedia
(
    MediaId         INT             IDENTITY(1,1)   NOT NULL,
    EventId         INT                             NOT NULL,
    MediaType       NVARCHAR(20)                    NOT NULL,
    BlobUrl         NVARCHAR(400)                   NOT NULL,
    Caption         NVARCHAR(200)                   NULL,
    IsPrimary       BIT                             NOT NULL CONSTRAINT DF_EventMedia_IsPrimary DEFAULT (0),
    UploadedById    INT                             NOT NULL,
    UploadedAt      DATETIME2(0)                    NOT NULL CONSTRAINT DF_EventMedia_UploadedAt DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_EventMedia             PRIMARY KEY (MediaId),
    CONSTRAINT FK_EventMedia_Events      FOREIGN KEY (EventId)      REFERENCES dbo.Events (EventId) ON DELETE CASCADE,
    CONSTRAINT FK_EventMedia_Uploader    FOREIGN KEY (UploadedById) REFERENCES dbo.Users (UserId),
    CONSTRAINT CK_EventMedia_Type        CHECK (MediaType IN (N'Banner', N'Gallery', N'RouteMap', N'Document'))
);
GO


/* ============================================================================
   6. PARTICIPATION TABLES
   ========================================================================== */

/* Enrolments ----------------------------------------------------------------
   A participant entering one category of one event. EventId is carried
   alongside CategoryId so that race numbers can be made unique per event and
   so that "my events" queries do not need an extra join. The composite foreign
   key (EventId, CategoryId) guarantees the two columns always agree, so an
   enrolment can never point at a category that belongs to a different event.
   Because that key uses NO ACTION, an event that already has enrolments
   cannot be deleted - historic results are protected by design.              */
CREATE TABLE dbo.Enrolments
(
    EnrolmentId     INT             IDENTITY(1,1)   NOT NULL,
    EventId         INT                             NOT NULL,
    CategoryId      INT                             NOT NULL,
    ParticipantId   INT                             NOT NULL,
    RaceNumber      NVARCHAR(12)                    NULL,
    Status          NVARCHAR(20)                    NOT NULL CONSTRAINT DF_Enrolments_Status     DEFAULT (N'Pending'),
    AmountDue       DECIMAL(8,2)                    NOT NULL,
    AmountPaid      DECIMAL(8,2)                    NOT NULL CONSTRAINT DF_Enrolments_AmountPaid DEFAULT (0),
    PaymentReference NVARCHAR(60)                   NULL,
    EstimatedFinishMinutes INT                      NULL,
    EnrolledAt      DATETIME2(0)                    NOT NULL CONSTRAINT DF_Enrolments_EnrolledAt DEFAULT (SYSUTCDATETIME()),
    CancelledAt     DATETIME2(0)                    NULL,
    CONSTRAINT PK_Enrolments                    PRIMARY KEY (EnrolmentId),
    CONSTRAINT UQ_Enrolments_OnePerCategory     UNIQUE      (CategoryId, ParticipantId),
    CONSTRAINT FK_Enrolments_EventCategory      FOREIGN KEY (EventId, CategoryId)
                                                    REFERENCES dbo.EventCategories (EventId, CategoryId),
    CONSTRAINT FK_Enrolments_Participant        FOREIGN KEY (ParticipantId) REFERENCES dbo.Users (UserId),
    CONSTRAINT CK_Enrolments_Status             CHECK (Status IN (N'Pending', N'Confirmed', N'Cancelled', N'Waitlisted')),
    CONSTRAINT CK_Enrolments_AmountDue          CHECK (AmountDue >= 0),
    CONSTRAINT CK_Enrolments_AmountPaid         CHECK (AmountPaid >= 0),
    CONSTRAINT CK_Enrolments_Cancelled          CHECK ((Status = N'Cancelled' AND CancelledAt IS NOT NULL)
                                                      OR (Status <> N'Cancelled' AND CancelledAt IS NULL))
);
GO


/* Results -------------------------------------------------------------------
   Captured by an organiser after the event. One result per enrolment,
   enforced by a UNIQUE constraint on EnrolmentId (one-to-one). Times are
   stored in whole seconds, which is how chip timing systems export them and
   which makes ordering and personal-best comparisons trivial.                */
CREATE TABLE dbo.Results
(
    ResultId            INT             IDENTITY(1,1)   NOT NULL,
    EnrolmentId         INT                             NOT NULL,
    FinishStatus        NVARCHAR(10)                    NOT NULL CONSTRAINT DF_Results_FinishStatus DEFAULT (N'Finished'),
    ChipTimeSeconds     INT                             NULL,
    GunTimeSeconds      INT                             NULL,
    PositionOverall     INT                             NULL,
    PositionGender      INT                             NULL,
    PositionCategory    INT                             NULL,
    AgeCategory         NVARCHAR(20)                    NULL,
    RecordedById        INT                             NOT NULL,
    RecordedAt          DATETIME2(0)                    NOT NULL CONSTRAINT DF_Results_RecordedAt DEFAULT (SYSUTCDATETIME()),
    Comment             NVARCHAR(300)                   NULL,
    CONSTRAINT PK_Results                   PRIMARY KEY (ResultId),
    CONSTRAINT UQ_Results_EnrolmentId       UNIQUE      (EnrolmentId),
    CONSTRAINT FK_Results_Enrolments        FOREIGN KEY (EnrolmentId)  REFERENCES dbo.Enrolments (EnrolmentId) ON DELETE CASCADE,
    CONSTRAINT FK_Results_RecordedBy        FOREIGN KEY (RecordedById) REFERENCES dbo.Users (UserId),
    CONSTRAINT CK_Results_FinishStatus      CHECK (FinishStatus IN (N'Finished', N'DNF', N'DNS', N'DSQ')),
    CONSTRAINT CK_Results_Times             CHECK (ChipTimeSeconds IS NULL OR ChipTimeSeconds > 0),
    CONSTRAINT CK_Results_GunTimes          CHECK (GunTimeSeconds IS NULL OR GunTimeSeconds > 0),
    CONSTRAINT CK_Results_Positions         CHECK (PositionOverall IS NULL OR PositionOverall > 0),
    /* A finisher must have a time; a non-finisher must not have one. */
    CONSTRAINT CK_Results_FinisherHasTime   CHECK ((FinishStatus = N'Finished' AND ChipTimeSeconds IS NOT NULL)
                                                  OR (FinishStatus <> N'Finished' AND ChipTimeSeconds IS NULL))
);
GO


/* ============================================================================
   7. INDEXES
   Non-clustered indexes on the columns the API filters and joins on most
   often. Primary keys and UNIQUE constraints already create their own
   indexes, so they are not repeated here.
   ========================================================================== */
CREATE INDEX IX_Users_RoleId              ON dbo.Users            (RoleId);
CREATE INDEX IX_Events_OrganiserId        ON dbo.Events           (OrganiserId);
CREATE INDEX IX_Events_EventDate_Status   ON dbo.Events           (EventDate, Status);
CREATE INDEX IX_Events_Province           ON dbo.Events           (Province);
CREATE INDEX IX_EventCategories_EventId   ON dbo.EventCategories  (EventId);
CREATE INDEX IX_Enrolments_ParticipantId  ON dbo.Enrolments       (ParticipantId);
CREATE INDEX IX_Enrolments_EventId_Status ON dbo.Enrolments       (EventId, Status);
GO

/* A race number must be unique inside an event, but an unpaid or cancelled
   enrolment has no race number yet. A plain UNIQUE constraint would treat two
   NULL race numbers in the same event as duplicates, so a filtered unique
   index is used instead - it only polices rows where a number has been issued. */
CREATE UNIQUE INDEX UX_Enrolments_RaceNumberPerEvent
    ON dbo.Enrolments (EventId, RaceNumber)
    WHERE RaceNumber IS NOT NULL;
GO


/* ============================================================================
   8. SEED DATA
   Meets and exceeds the brief: 2 organisers, 3 participants, 3 events,
   categories for every event, routes, media, enrolments and results.
   All people, clubs and events below are fictional but realistic.
   ========================================================================== */

/* -- 8.1 Roles ------------------------------------------------------------ */
INSERT INTO dbo.Roles (RoleName, Description)
VALUES (N'Organiser',   N'Creates and manages events, categories and results.'),
       (N'Participant', N'Browses events, enters categories and tracks results.');
GO

DECLARE @OrganiserRole   INT = (SELECT RoleId FROM dbo.Roles WHERE RoleName = N'Organiser');
DECLARE @ParticipantRole INT = (SELECT RoleId FROM dbo.Roles WHERE RoleName = N'Participant');

/* -- 8.2 Users -----------------------------------------------------------------
   PasswordHash and PasswordSalt below are clearly marked PLACEHOLDER values so
   that the schema can be demonstrated. Part 2 replaces them with real BCrypt
   hashes generated by the API at registration; no plain-text password is ever
   stored. The demonstration password for every seeded account is Race@2026.  */
INSERT INTO dbo.Users (RoleId, FirstName, LastName, Email, PasswordHash, PasswordSalt,
                       PhoneNumber, DateOfBirth, Gender, Province)
VALUES
    (@OrganiserRole,   N'Thandeka', N'Mahlangu', N'thandeka@highveldathletics.co.za',
        N'PLACEHOLDER_BCRYPT_HASH_ORG_01', N'PLACEHOLDER_SALT_ORG_01', N'082 555 0110', '1985-04-12', N'Female', N'Gauteng'),
    (@OrganiserRole,   N'Riaan',    N'Botha',    N'riaan@peninsulacycling.co.za',
        N'PLACEHOLDER_BCRYPT_HASH_ORG_02', N'PLACEHOLDER_SALT_ORG_02', N'083 555 0244', '1979-09-30', N'Male',   N'Western Cape'),
    (@ParticipantRole, N'Lerato',   N'Mokoena',  N'lerato.mokoena@example.co.za',
        N'PLACEHOLDER_BCRYPT_HASH_PAR_01', N'PLACEHOLDER_SALT_PAR_01', N'084 555 0317', '1996-02-18', N'Female', N'Gauteng'),
    (@ParticipantRole, N'Sipho',    N'Dlamini',  N'sipho.dlamini@example.co.za',
        N'PLACEHOLDER_BCRYPT_HASH_PAR_02', N'PLACEHOLDER_SALT_PAR_02', N'071 555 0492', '1991-11-05', N'Male',   N'KwaZulu-Natal'),
    (@ParticipantRole, N'Anika',    N'van Wyk',  N'anika.vanwyk@example.co.za',
        N'PLACEHOLDER_BCRYPT_HASH_PAR_03', N'PLACEHOLDER_SALT_PAR_03', N'072 555 0688', '2001-06-24', N'Female', N'Western Cape');
GO

/* -- 8.3 Participant profiles ------------------------------------------------
   One profile per participant. Organisers deliberately have no profile row.  */
INSERT INTO dbo.ParticipantProfiles (UserId, ClubName, AthleticsNumber, TshirtSize,
                                     EmergencyContactName, EmergencyContactPhone,
                                     MedicalAidScheme, MedicalNotes)
SELECT UserId, N'Randburg Harriers', N'CGA-2024-11487', N'S',
       N'Mpho Mokoena', N'082 555 0318', N'Discovery Health', N'Mild asthma - carries an inhaler.'
FROM dbo.Users WHERE Email = N'lerato.mokoena@example.co.za';

INSERT INTO dbo.ParticipantProfiles (UserId, ClubName, AthleticsNumber, TshirtSize,
                                     EmergencyContactName, EmergencyContactPhone,
                                     MedicalAidScheme, MedicalNotes)
SELECT UserId, N'Durban Athletic Club', N'KZN-2023-06612', N'L',
       N'Nomusa Dlamini', N'073 555 0491', N'Bonitas', NULL
FROM dbo.Users WHERE Email = N'sipho.dlamini@example.co.za';

INSERT INTO dbo.ParticipantProfiles (UserId, ClubName, AthleticsNumber, TshirtSize,
                                     EmergencyContactName, EmergencyContactPhone,
                                     MedicalAidScheme, MedicalNotes)
SELECT UserId, N'Tygerberg Cycling Club', NULL, N'M',
       N'Johan van Wyk', N'082 555 0687', N'Momentum', NULL
FROM dbo.Users WHERE Email = N'anika.vanwyk@example.co.za';
GO

/* -- 8.4 Events ------------------------------------------------------------ */
DECLARE @Thandeka INT = (SELECT UserId FROM dbo.Users WHERE Email = N'thandeka@highveldathletics.co.za');
DECLARE @Riaan    INT = (SELECT UserId FROM dbo.Users WHERE Email = N'riaan@peninsulacycling.co.za');

INSERT INTO dbo.Events (OrganiserId, EventName, Slug, Discipline, Description, EventDate, StartTime,
                        VenueName, StreetAddress, City, Province, Latitude, Longitude,
                        RegistrationOpensAt, RegistrationClosesAt, Status, IsLicensed)
VALUES
    (@Thandeka, N'Highveld Half Marathon 2026', N'highveld-half-marathon-2026', N'Running',
        N'A fast, licensed half marathon on the closed roads of Randburg, with a 10km road race and a 5km community walk starting from the same venue.',
        '2026-10-11', '06:00', N'Randburg Sports Complex', N'Hendrik Verwoerd Drive, Ferndale',
        N'Randburg', N'Gauteng', -26.097500, 27.995500,
        '2026-07-01T08:00:00', '2026-10-05T23:59:00', N'Published', 1),

    (@Riaan,    N'Peninsula Charity Cycle 2026', N'peninsula-charity-cycle-2026', N'Cycling',
        N'A charity road cycle around the Cape Peninsula in aid of township learn-to-swim programmes, with a 105km main route, a 45km option and a 20km family ride.',
        '2026-11-08', '06:30', N'Green Point Athletics Stadium', N'Fritz Sonnenberg Road, Green Point',
        N'Cape Town', N'Western Cape', -33.903400, 18.410300,
        '2026-08-01T08:00:00', '2026-11-01T23:59:00', N'Published', 1),

    (@Thandeka, N'Durban Beachfront Night Run 2026', N'durban-beachfront-night-run-2026', N'Running',
        N'An evening 15km and 8km run along the Golden Mile promenade, plus a 3km glow walk for families.',
        '2026-12-05', '18:30', N'uShaka Marine World Parking', N'1 King Shaka Avenue, Point',
        N'Durban', N'KwaZulu-Natal', -29.867300, 31.044700,
        '2026-09-15T08:00:00', '2026-11-28T23:59:00', N'Published', 0);
GO

/* -- 8.5 Event categories -------------------------------------------------- */
DECLARE @Highveld INT = (SELECT EventId FROM dbo.Events WHERE Slug = N'highveld-half-marathon-2026');
DECLARE @Cycle    INT = (SELECT EventId FROM dbo.Events WHERE Slug = N'peninsula-charity-cycle-2026');
DECLARE @NightRun INT = (SELECT EventId FROM dbo.Events WHERE Slug = N'durban-beachfront-night-run-2026');

INSERT INTO dbo.EventCategories (EventId, CategoryName, DistanceKm, EntryFee, ParticipantLimit,
                                 MinimumAge, StartTime, CutOffMinutes, IsTimed)
VALUES
    (@Highveld, N'21.1km Half Marathon', 21.10, 220.00, 2500, 16, '06:00', 210, 1),
    (@Highveld, N'10km Road Race',       10.00, 150.00, 1800, 14, '06:30', 120, 1),
    (@Highveld, N'5km Community Walk',    5.00,  80.00, 1200,  0, '07:00', NULL, 0),

    (@Cycle,    N'105km Peninsula Route', 105.00, 480.00, 3000, 18, '06:30', 420, 1),
    (@Cycle,    N'45km Coastal Route',     45.00, 320.00, 2000, 14, '07:30', 240, 1),
    (@Cycle,    N'20km Family Ride',       20.00, 180.00, 1500,  8, '09:00', NULL, 0),

    (@NightRun, N'15km Promenade Run',     15.00, 190.00, 1500, 16, '18:30', 150, 1),
    (@NightRun, N'8km Sunset Run',          8.00, 130.00, 1200, 12, '18:45', 100, 1),
    (@NightRun, N'3km Glow Walk',           3.00,  70.00,  900,  0, '19:15', NULL, 0);
GO

/* -- 8.6 Event routes ------------------------------------------------------ */
INSERT INTO dbo.EventRoutes (CategoryId, RouteName, TerrainType, ElevationGainM, WaterPointCount, GpxBlobUrl, RouteNotes)
SELECT c.CategoryId,
       N'Ferndale loop (two laps)', N'Road', 186, 5,
       N'https://racedaystorage.blob.core.windows.net/routes/highveld-21km.gpx',
       N'Two identical laps through Ferndale and Blairgowrie. One short climb on Bram Fischer Drive at 7km and 18km.'
FROM dbo.EventCategories c
JOIN dbo.Events e ON e.EventId = c.EventId
WHERE e.Slug = N'highveld-half-marathon-2026' AND c.CategoryName = N'21.1km Half Marathon';

INSERT INTO dbo.EventRoutes (CategoryId, RouteName, TerrainType, ElevationGainM, WaterPointCount, GpxBlobUrl, RouteNotes)
SELECT c.CategoryId,
       N'Chapman''s Peak and Ou Kaapse Weg', N'Road', 1240, 8,
       N'https://racedaystorage.blob.core.windows.net/routes/peninsula-105km.gpx',
       N'Long climb from Hout Bay onto Chapman''s Peak at 48km. Strong south-easter is likely after 09:00.'
FROM dbo.EventCategories c
JOIN dbo.Events e ON e.EventId = c.EventId
WHERE e.Slug = N'peninsula-charity-cycle-2026' AND c.CategoryName = N'105km Peninsula Route';

INSERT INTO dbo.EventRoutes (CategoryId, RouteName, TerrainType, ElevationGainM, WaterPointCount, GpxBlobUrl, RouteNotes)
SELECT c.CategoryId,
       N'Golden Mile out and back', N'Promenade', 24, 4,
       N'https://racedaystorage.blob.core.windows.net/routes/durban-15km.gpx',
       N'Flat and fully lit. Turnaround at the Suncoast pier. Humidity is typically above 70 per cent.'
FROM dbo.EventCategories c
JOIN dbo.Events e ON e.EventId = c.EventId
WHERE e.Slug = N'durban-beachfront-night-run-2026' AND c.CategoryName = N'15km Promenade Run';
GO

/* -- 8.7 Event media ------------------------------------------------------- */
INSERT INTO dbo.EventMedia (EventId, MediaType, BlobUrl, Caption, IsPrimary, UploadedById)
SELECT e.EventId, N'Banner',
       N'https://racedaystorage.blob.core.windows.net/events/highveld-2026-banner.jpg',
       N'Start chute at the 2025 Highveld Half Marathon.', 1, e.OrganiserId
FROM dbo.Events e WHERE e.Slug = N'highveld-half-marathon-2026';

INSERT INTO dbo.EventMedia (EventId, MediaType, BlobUrl, Caption, IsPrimary, UploadedById)
SELECT e.EventId, N'RouteMap',
       N'https://racedaystorage.blob.core.windows.net/events/peninsula-2026-routemap.png',
       N'Official 105km route map with water points marked.', 1, e.OrganiserId
FROM dbo.Events e WHERE e.Slug = N'peninsula-charity-cycle-2026';

INSERT INTO dbo.EventMedia (EventId, MediaType, BlobUrl, Caption, IsPrimary, UploadedById)
SELECT e.EventId, N'Document',
       N'https://racedaystorage.blob.core.windows.net/events/durban-2026-race-info.pdf',
       N'Race information pack and indemnity form.', 0, e.OrganiserId
FROM dbo.Events e WHERE e.Slug = N'durban-beachfront-night-run-2026';
GO

/* -- 8.8 Enrolments -------------------------------------------------------- */
DECLARE @Lerato INT = (SELECT UserId FROM dbo.Users WHERE Email = N'lerato.mokoena@example.co.za');
DECLARE @Sipho  INT = (SELECT UserId FROM dbo.Users WHERE Email = N'sipho.dlamini@example.co.za');
DECLARE @Anika  INT = (SELECT UserId FROM dbo.Users WHERE Email = N'anika.vanwyk@example.co.za');

/* Lerato: half marathon (confirmed, raced) and the Durban 15km (confirmed) */
INSERT INTO dbo.Enrolments (EventId, CategoryId, ParticipantId, RaceNumber, Status, AmountDue, AmountPaid, PaymentReference, EstimatedFinishMinutes)
SELECT c.EventId, c.CategoryId, @Lerato, N'A1042', N'Confirmed', c.EntryFee, c.EntryFee, N'PF-8841207', 118
FROM dbo.EventCategories c JOIN dbo.Events e ON e.EventId = c.EventId
WHERE e.Slug = N'highveld-half-marathon-2026' AND c.CategoryName = N'21.1km Half Marathon';

INSERT INTO dbo.Enrolments (EventId, CategoryId, ParticipantId, RaceNumber, Status, AmountDue, AmountPaid, PaymentReference, EstimatedFinishMinutes)
SELECT c.EventId, c.CategoryId, @Lerato, N'D0318', N'Confirmed', c.EntryFee, c.EntryFee, N'PF-9002544', 82
FROM dbo.EventCategories c JOIN dbo.Events e ON e.EventId = c.EventId
WHERE e.Slug = N'durban-beachfront-night-run-2026' AND c.CategoryName = N'15km Promenade Run';

/* Sipho: half marathon 10km (confirmed, raced) and the 105km cycle (pending payment) */
INSERT INTO dbo.Enrolments (EventId, CategoryId, ParticipantId, RaceNumber, Status, AmountDue, AmountPaid, PaymentReference, EstimatedFinishMinutes)
SELECT c.EventId, c.CategoryId, @Sipho, N'A2205', N'Confirmed', c.EntryFee, c.EntryFee, N'PF-8841311', 52
FROM dbo.EventCategories c JOIN dbo.Events e ON e.EventId = c.EventId
WHERE e.Slug = N'highveld-half-marathon-2026' AND c.CategoryName = N'10km Road Race';

INSERT INTO dbo.Enrolments (EventId, CategoryId, ParticipantId, RaceNumber, Status, AmountDue, AmountPaid, PaymentReference, EstimatedFinishMinutes)
SELECT c.EventId, c.CategoryId, @Sipho, NULL, N'Pending', c.EntryFee, 0, NULL, 300
FROM dbo.EventCategories c JOIN dbo.Events e ON e.EventId = c.EventId
WHERE e.Slug = N'peninsula-charity-cycle-2026' AND c.CategoryName = N'105km Peninsula Route';

/* Anika: 45km cycle (confirmed) and the 5km walk (cancelled, to exercise the CHECK constraint) */
INSERT INTO dbo.Enrolments (EventId, CategoryId, ParticipantId, RaceNumber, Status, AmountDue, AmountPaid, PaymentReference, EstimatedFinishMinutes)
SELECT c.EventId, c.CategoryId, @Anika, N'C1176', N'Confirmed', c.EntryFee, c.EntryFee, N'PF-9114820', 95
FROM dbo.EventCategories c JOIN dbo.Events e ON e.EventId = c.EventId
WHERE e.Slug = N'peninsula-charity-cycle-2026' AND c.CategoryName = N'45km Coastal Route';

INSERT INTO dbo.Enrolments (EventId, CategoryId, ParticipantId, RaceNumber, Status, AmountDue, AmountPaid, CancelledAt)
SELECT c.EventId, c.CategoryId, @Anika, NULL, N'Cancelled', c.EntryFee, 0, '2026-09-20T10:12:00'
FROM dbo.EventCategories c JOIN dbo.Events e ON e.EventId = c.EventId
WHERE e.Slug = N'highveld-half-marathon-2026' AND c.CategoryName = N'5km Community Walk';
GO

/* -- 8.9 Results ------------------------------------------------------------
   Captured by the organiser who owns the event. Times are in whole seconds:
   1:58:37 = 7117 seconds, 51:44 = 3104 seconds.                             */
DECLARE @Thandeka2 INT = (SELECT UserId FROM dbo.Users WHERE Email = N'thandeka@highveldathletics.co.za');

INSERT INTO dbo.Results (EnrolmentId, FinishStatus, ChipTimeSeconds, GunTimeSeconds,
                         PositionOverall, PositionGender, PositionCategory, AgeCategory,
                         RecordedById, Comment)
SELECT en.EnrolmentId, N'Finished', 7117, 7154, 214, 38, 12, N'Senior Female 30-39', @Thandeka2,
       N'Personal best by just over two minutes.'
FROM dbo.Enrolments en WHERE en.RaceNumber = N'A1042';

INSERT INTO dbo.Results (EnrolmentId, FinishStatus, ChipTimeSeconds, GunTimeSeconds,
                         PositionOverall, PositionGender, PositionCategory, AgeCategory,
                         RecordedById, Comment)
SELECT en.EnrolmentId, N'Finished', 3104, 3122, 96, 71, 20, N'Senior Male 30-39', @Thandeka2, NULL
FROM dbo.Enrolments en WHERE en.RaceNumber = N'A2205';
GO


/* ============================================================================
   9. VERIFICATION QUERIES
   Run these after the script to confirm the schema and the seed data. Each
   query also demonstrates a relationship from the ERD.
   ========================================================================== */

/* 9.1 Row counts per table ------------------------------------------------ */
SELECT N'Roles' AS TableName, COUNT(*) AS RowsLoaded FROM dbo.Roles
UNION ALL SELECT N'Users',               COUNT(*) FROM dbo.Users
UNION ALL SELECT N'ParticipantProfiles', COUNT(*) FROM dbo.ParticipantProfiles
UNION ALL SELECT N'Events',              COUNT(*) FROM dbo.Events
UNION ALL SELECT N'EventCategories',     COUNT(*) FROM dbo.EventCategories
UNION ALL SELECT N'EventRoutes',         COUNT(*) FROM dbo.EventRoutes
UNION ALL SELECT N'EventMedia',          COUNT(*) FROM dbo.EventMedia
UNION ALL SELECT N'Enrolments',          COUNT(*) FROM dbo.Enrolments
UNION ALL SELECT N'Results',             COUNT(*) FROM dbo.Results;

/* 9.2 Published events with their organiser and category count ------------ */
SELECT  e.EventName,
        e.EventDate,
        e.City,
        e.Province,
        CONCAT(u.FirstName, N' ', u.LastName) AS Organiser,
        COUNT(c.CategoryId)                   AS Categories
FROM        dbo.Events          AS e
INNER JOIN  dbo.Users           AS u ON u.UserId  = e.OrganiserId
LEFT  JOIN  dbo.EventCategories AS c ON c.EventId = e.EventId
WHERE   e.Status = N'Published'
GROUP BY e.EventName, e.EventDate, e.City, e.Province, u.FirstName, u.LastName
ORDER BY e.EventDate;

/* 9.3 A participant's personal history, formatted as hh:mm:ss ------------- */
SELECT  CONCAT(u.FirstName, N' ', u.LastName) AS Participant,
        e.EventName,
        c.CategoryName,
        c.DistanceKm,
        en.RaceNumber,
        en.Status                             AS EnrolmentStatus,
        r.FinishStatus,
        CONVERT(VARCHAR(8), DATEADD(SECOND, r.ChipTimeSeconds, CAST('00:00:00' AS TIME)), 108) AS ChipTime,
        r.PositionOverall
FROM        dbo.Enrolments      AS en
INNER JOIN  dbo.Users           AS u  ON u.UserId     = en.ParticipantId
INNER JOIN  dbo.EventCategories AS c  ON c.CategoryId = en.CategoryId
INNER JOIN  dbo.Events          AS e  ON e.EventId    = en.EventId
LEFT  JOIN  dbo.Results         AS r  ON r.EnrolmentId = en.EnrolmentId
WHERE   u.Email = N'lerato.mokoena@example.co.za'
ORDER BY e.EventDate;

/* 9.4 Entry revenue per event (confirmed enrolments only) ----------------- */
SELECT  e.EventName,
        COUNT(en.EnrolmentId) AS ConfirmedEntries,
        SUM(en.AmountPaid)    AS RevenueZar
FROM        dbo.Events     AS e
LEFT  JOIN  dbo.Enrolments AS en ON en.EventId = e.EventId AND en.Status = N'Confirmed'
GROUP BY e.EventName
ORDER BY RevenueZar DESC;
GO
