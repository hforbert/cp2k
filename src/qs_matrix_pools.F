!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright 2000-2025 CP2K developers group <https://cp2k.org>                                   !
!                                                                                                  !
!   SPDX-License-Identifier: GPL-2.0-or-later                                                      !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief wrapper for the pools of matrixes
!> \par History
!>      05.2003 created [fawzi]
!> \author fawzi
! **************************************************************************************************
MODULE qs_matrix_pools
   USE cp_blacs_env,                    ONLY: cp_blacs_env_type
   USE cp_fm_pool_types,                ONLY: cp_fm_pool_p_type,&
                                              cp_fm_pool_type,&
                                              fm_pool_create,&
                                              fm_pool_get_el_struct,&
                                              fm_pool_release,&
                                              fm_pool_retain,&
                                              fm_pools_dealloc
   USE cp_fm_struct,                    ONLY: cp_fm_struct_create,&
                                              cp_fm_struct_get,&
                                              cp_fm_struct_release,&
                                              cp_fm_struct_type
   USE message_passing,                 ONLY: mp_para_env_type
   USE qs_mo_types,                     ONLY: get_mo_set,&
                                              mo_set_type
#include "./base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   LOGICAL, PRIVATE, PARAMETER :: debug_this_module = .TRUE.
   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'qs_matrix_pools'

   PUBLIC :: qs_matrix_pools_type
   PUBLIC :: mpools_retain, mpools_release, mpools_get, &
             mpools_create, mpools_rebuild_fm_pools

! **************************************************************************************************
!> \brief container for the pools of matrixes used by qs
!> \param ref_count reference count (see doc/ReferenceCounting.html)
!> \param ao_mo_fm_pools pools with (ao x mo) full matrixes (same order as
!>        c).
!> \param ao_ao_fm_pools pools with (ao x ao) full matrixes (same order as
!>        c).
!> \param mo_mo_fm_pools pools with (mo x mo) full matrixes (same
!>        order as c).
!> \param ao_mosub_fm_pools pools with (ao x mosub) full matrixes, where mosub
!>        are a subset of the mos
!> \param mosub_mosub_fm_pools pools with (mosub x mosub) full matrixes, where mosub
!>        are a subset of the mos
!>
!> \param maxao_maxao_fm_pools pool of matrixes big enough to accommodate any
!>        aoxao matrix (useful for temp matrixes)
!> \param maxao_maxmo_fm_pools pool of matrixes big enough to accommodate any
!>        aoxmo matrix (useful for temp matrixes)
!> \param maxmo_maxmo_fm_pools pool of matrixes big enough to accommodate any
!>        moxmo matrix (useful for temp matrixes)
!> \par History
!>      04.2003 created [fawzi]
!> \author fawzi
! **************************************************************************************************
   TYPE qs_matrix_pools_type
      INTEGER :: ref_count = -1
      TYPE(cp_fm_pool_p_type), DIMENSION(:), POINTER        :: ao_mo_fm_pools => NULL(), &
                                                               ao_ao_fm_pools => NULL(), mo_mo_fm_pools => NULL()
      TYPE(cp_fm_pool_p_type), DIMENSION(:), POINTER        :: ao_mosub_fm_pools => NULL(), &
                                                               mosub_mosub_fm_pools => NULL()
   END TYPE qs_matrix_pools_type

CONTAINS

! **************************************************************************************************
!> \brief retains the given qs_matrix_pools_type
!> \param mpools the matrix pools type to retain
!> \par History
!>      04.2003 created [fawzi]
!> \author fawzi
! **************************************************************************************************
   SUBROUTINE mpools_retain(mpools)
      TYPE(qs_matrix_pools_type), POINTER                :: mpools

      CPASSERT(ASSOCIATED(mpools))
      CPASSERT(mpools%ref_count > 0)
      mpools%ref_count = mpools%ref_count + 1
   END SUBROUTINE mpools_retain

! **************************************************************************************************
!> \brief releases the given mpools
!> \param mpools the matrix pools type to retain
!> \par History
!>      04.2003 created [fawzi]
!> \author fawzi
! **************************************************************************************************
   SUBROUTINE mpools_release(mpools)
      TYPE(qs_matrix_pools_type), POINTER                :: mpools

      IF (ASSOCIATED(mpools)) THEN
         CPASSERT(mpools%ref_count > 0)
         mpools%ref_count = mpools%ref_count - 1
         IF (mpools%ref_count == 0) THEN
            CALL fm_pools_dealloc(mpools%ao_mo_fm_pools)
            CALL fm_pools_dealloc(mpools%ao_ao_fm_pools)
            CALL fm_pools_dealloc(mpools%mo_mo_fm_pools)
            IF (ASSOCIATED(mpools%ao_mosub_fm_pools)) THEN
               CALL fm_pools_dealloc(mpools%ao_mosub_fm_pools)
            END IF
            IF (ASSOCIATED(mpools%mosub_mosub_fm_pools)) THEN
               CALL fm_pools_dealloc(mpools%mosub_mosub_fm_pools)
            END IF
            DEALLOCATE (mpools)
         END IF
      END IF
      NULLIFY (mpools)
   END SUBROUTINE mpools_release

! **************************************************************************************************
!> \brief returns various attributes of the mpools (notably the pools
!>      contained in it)
!> \param mpools the matrix pools object you want info about
!> \param ao_mo_fm_pools ...
!> \param ao_ao_fm_pools ...
!> \param mo_mo_fm_pools ...
!> \param ao_mosub_fm_pools ...
!> \param mosub_mosub_fm_pools ...
!> \param maxao_maxmo_fm_pool ...
!> \param maxao_maxao_fm_pool ...
!> \param maxmo_maxmo_fm_pool ...
!> \par History
!>      04.2003 created [fawzi]
!> \author fawzi
! **************************************************************************************************
   SUBROUTINE mpools_get(mpools, ao_mo_fm_pools, ao_ao_fm_pools, &
                         mo_mo_fm_pools, ao_mosub_fm_pools, mosub_mosub_fm_pools, &
                         maxao_maxmo_fm_pool, maxao_maxao_fm_pool, maxmo_maxmo_fm_pool)
      TYPE(qs_matrix_pools_type), INTENT(IN)             :: mpools
      TYPE(cp_fm_pool_p_type), DIMENSION(:), OPTIONAL, &
         POINTER                                         :: ao_mo_fm_pools, ao_ao_fm_pools, &
                                                            mo_mo_fm_pools, ao_mosub_fm_pools, &
                                                            mosub_mosub_fm_pools
      TYPE(cp_fm_pool_type), OPTIONAL, POINTER           :: maxao_maxmo_fm_pool, &
                                                            maxao_maxao_fm_pool, &
                                                            maxmo_maxmo_fm_pool

      IF (PRESENT(ao_mo_fm_pools)) ao_mo_fm_pools => mpools%ao_mo_fm_pools
      IF (PRESENT(maxao_maxmo_fm_pool)) THEN
         IF (ASSOCIATED(mpools%ao_mo_fm_pools)) THEN
            maxao_maxmo_fm_pool => mpools%ao_mo_fm_pools(1)%pool
         ELSE
            NULLIFY (maxao_maxmo_fm_pool) ! raise an error?
         END IF
      END IF
      IF (PRESENT(ao_ao_fm_pools)) ao_ao_fm_pools => mpools%ao_ao_fm_pools
      IF (PRESENT(maxao_maxao_fm_pool)) THEN
         IF (ASSOCIATED(mpools%ao_ao_fm_pools)) THEN
            maxao_maxao_fm_pool => mpools%ao_ao_fm_pools(1)%pool
         ELSE
            NULLIFY (maxao_maxao_fm_pool) ! raise an error?
         END IF
      END IF
      IF (PRESENT(mo_mo_fm_pools)) mo_mo_fm_pools => mpools%mo_mo_fm_pools
      IF (PRESENT(maxmo_maxmo_fm_pool)) THEN
         IF (ASSOCIATED(mpools%mo_mo_fm_pools)) THEN
            maxmo_maxmo_fm_pool => mpools%mo_mo_fm_pools(1)%pool
         ELSE
            NULLIFY (maxmo_maxmo_fm_pool) ! raise an error?
         END IF
      END IF
      IF (PRESENT(ao_mosub_fm_pools)) ao_mosub_fm_pools => mpools%ao_mosub_fm_pools
      IF (PRESENT(mosub_mosub_fm_pools)) mosub_mosub_fm_pools => mpools%mosub_mosub_fm_pools
   END SUBROUTINE mpools_get

! **************************************************************************************************
!> \brief creates a mpools
!> \param mpools the mpools to create
!> \par History
!>      04.2003 created [fawzi]
!> \author fawzi
! **************************************************************************************************
   SUBROUTINE mpools_create(mpools)
      TYPE(qs_matrix_pools_type), POINTER                :: mpools

      ALLOCATE (mpools)
      NULLIFY (mpools%ao_ao_fm_pools, mpools%ao_mo_fm_pools, &
               mpools%mo_mo_fm_pools, mpools%ao_mosub_fm_pools, &
               mpools%mosub_mosub_fm_pools)
      mpools%ref_count = 1
   END SUBROUTINE mpools_create

! **************************************************************************************************
!> \brief rebuilds the pools of the (ao x mo, ao x ao , mo x mo) full matrixes
!> \param mpools the environment where the pools should be rebuilt
!> \param mos the molecular orbitals (qs_env%c), must contain up to
!>        date nmo and nao
!> \param blacs_env the blacs environment of the full matrixes
!> \param para_env the parallel environment of the matrixes
!> \param nmosub number of the orbitals for the creation
!>        of the pools containing only a subset of mos (OPTIONAL)
!> \par History
!>      08.2002 created [fawzi]
!>      04.2005 added pools for a subset of mos [MI]
!> \author Fawzi Mohamed
! **************************************************************************************************
   SUBROUTINE mpools_rebuild_fm_pools(mpools, mos, blacs_env, para_env, &
                                      nmosub)
      TYPE(qs_matrix_pools_type), POINTER                :: mpools
      TYPE(mo_set_type), DIMENSION(:), INTENT(IN)        :: mos
      TYPE(cp_blacs_env_type), POINTER                   :: blacs_env
      TYPE(mp_para_env_type), POINTER                    :: para_env
      INTEGER, DIMENSION(2), INTENT(IN), OPTIONAL        :: nmosub

      CHARACTER(len=*), PARAMETER :: routineN = 'mpools_rebuild_fm_pools'

      INTEGER                                            :: handle, ispin, max_nmo, min_nmo, nao, &
                                                            ncg, nmo, nrg, nspins
      LOGICAL                                            :: prepare_subset, should_rebuild
      TYPE(cp_fm_pool_type), POINTER                     :: p_att
      TYPE(cp_fm_struct_type), POINTER                   :: fmstruct

      CALL timeset(routineN, handle)

      NULLIFY (fmstruct, p_att)
      prepare_subset = .FALSE.
      IF (PRESENT(nmosub)) THEN
         IF (nmosub(1) > 0) prepare_subset = .TRUE.
      END IF

      IF (.NOT. ASSOCIATED(mpools)) THEN
         CALL mpools_create(mpools)
      END IF
      nspins = SIZE(mos)

      IF (ASSOCIATED(mpools%ao_mo_fm_pools)) THEN
         IF (nspins /= SIZE(mpools%ao_mo_fm_pools)) THEN
            CALL fm_pools_dealloc(mpools%ao_mo_fm_pools)
         END IF
      END IF
      IF (.NOT. ASSOCIATED(mpools%ao_mo_fm_pools)) THEN
         ALLOCATE (mpools%ao_mo_fm_pools(nspins))
         DO ispin = 1, nspins
            NULLIFY (mpools%ao_mo_fm_pools(ispin)%pool)
         END DO
      END IF

      IF (ASSOCIATED(mpools%ao_ao_fm_pools)) THEN
         IF (nspins /= SIZE(mpools%ao_ao_fm_pools)) THEN
            CALL fm_pools_dealloc(mpools%ao_ao_fm_pools)
         END IF
      END IF
      IF (.NOT. ASSOCIATED(mpools%ao_ao_fm_pools)) THEN
         ALLOCATE (mpools%ao_ao_fm_pools(nspins))
         DO ispin = 1, nspins
            NULLIFY (mpools%ao_ao_fm_pools(ispin)%pool)
         END DO
      END IF

      IF (ASSOCIATED(mpools%mo_mo_fm_pools)) THEN
         IF (nspins /= SIZE(mpools%mo_mo_fm_pools)) THEN
            CALL fm_pools_dealloc(mpools%mo_mo_fm_pools)
         END IF
      END IF
      IF (.NOT. ASSOCIATED(mpools%mo_mo_fm_pools)) THEN
         ALLOCATE (mpools%mo_mo_fm_pools(nspins))
         DO ispin = 1, nspins
            NULLIFY (mpools%mo_mo_fm_pools(ispin)%pool)
         END DO
      END IF

      IF (prepare_subset) THEN

         IF (ASSOCIATED(mpools%ao_mosub_fm_pools)) THEN
            IF (nspins /= SIZE(mpools%ao_mosub_fm_pools)) THEN
               CALL fm_pools_dealloc(mpools%ao_mosub_fm_pools)
            END IF
         END IF
         IF (.NOT. ASSOCIATED(mpools%ao_mosub_fm_pools)) THEN
            ALLOCATE (mpools%ao_mosub_fm_pools(nspins))
            DO ispin = 1, nspins
               NULLIFY (mpools%ao_mosub_fm_pools(ispin)%pool)
            END DO
         END IF

         IF (ASSOCIATED(mpools%mosub_mosub_fm_pools)) THEN
            IF (nspins /= SIZE(mpools%mosub_mosub_fm_pools)) THEN
               CALL fm_pools_dealloc(mpools%mosub_mosub_fm_pools)
            END IF
         END IF
         IF (.NOT. ASSOCIATED(mpools%mosub_mosub_fm_pools)) THEN
            ALLOCATE (mpools%mosub_mosub_fm_pools(nspins))
            DO ispin = 1, nspins
               NULLIFY (mpools%mosub_mosub_fm_pools(ispin)%pool)
            END DO
         END IF

      END IF ! prepare_subset

      CALL get_mo_set(mos(1), nao=nao, nmo=min_nmo)
      max_nmo = min_nmo
      DO ispin = 2, SIZE(mos)
         CALL get_mo_set(mos(ispin), nmo=nmo)
         IF (max_nmo < nmo) THEN
            CPABORT("the mo with the most orbitals must be the first ")
         END IF
         min_nmo = MIN(min_nmo, nmo)
      END DO

      ! aoao pools
      should_rebuild = .FALSE.
      DO ispin = 1, nspins
         p_att => mpools%ao_ao_fm_pools(ispin)%pool
         should_rebuild = (should_rebuild .OR. (.NOT. ASSOCIATED(p_att)))
         IF (.NOT. should_rebuild) THEN
            fmstruct => fm_pool_get_el_struct(mpools%ao_ao_fm_pools(ispin)%pool)
            CALL cp_fm_struct_get(fmstruct, nrow_global=nrg, ncol_global=ncg)
            CALL get_mo_set(mos(1), nao=nao, nmo=nmo)
            should_rebuild = nao /= nrg .OR. nao /= ncg
         END IF
      END DO
      IF (should_rebuild) THEN
         DO ispin = 1, nspins
            CALL fm_pool_release(mpools%ao_ao_fm_pools(ispin)%pool)
         END DO

         CALL cp_fm_struct_create(fmstruct, nrow_global=nao, &
                                  ncol_global=nao, para_env=para_env, &
                                  context=blacs_env)
         CALL fm_pool_create(mpools%ao_ao_fm_pools(1)%pool, fmstruct)
         CALL cp_fm_struct_release(fmstruct)
         DO ispin = 2, SIZE(mos)
            mpools%ao_ao_fm_pools(ispin)%pool => mpools%ao_ao_fm_pools(1)%pool
            CALL fm_pool_retain(mpools%ao_ao_fm_pools(1)%pool)
         END DO
      END IF

      ! aomo pools
      should_rebuild = .FALSE.
      DO ispin = 1, nspins
         p_att => mpools%ao_mo_fm_pools(ispin)%pool
         should_rebuild = (should_rebuild .OR. (.NOT. ASSOCIATED(p_att)))
         IF (.NOT. should_rebuild) THEN
            fmstruct => fm_pool_get_el_struct(mpools%ao_mo_fm_pools(ispin) &
                                              %pool)
            CALL cp_fm_struct_get(fmstruct, nrow_global=nrg, ncol_global=ncg)
            CALL get_mo_set(mos(1), nao=nao, nmo=nmo)
            should_rebuild = nao /= nrg .OR. nmo /= ncg
         END IF
      END DO
      IF (should_rebuild) THEN
         DO ispin = 1, nspins
            CALL fm_pool_release(mpools%ao_mo_fm_pools(ispin)%pool)
         END DO

         IF (max_nmo == min_nmo) THEN
            CALL cp_fm_struct_create(fmstruct, nrow_global=nao, &
                                     ncol_global=max_nmo, para_env=para_env, &
                                     context=blacs_env)
            CALL fm_pool_create(mpools%ao_mo_fm_pools(1)%pool, fmstruct)
            CALL cp_fm_struct_release(fmstruct)
            DO ispin = 2, SIZE(mos)
               mpools%ao_mo_fm_pools(ispin)%pool => mpools%ao_mo_fm_pools(1)%pool
               CALL fm_pool_retain(mpools%ao_mo_fm_pools(1)%pool)
            END DO
         ELSE
            DO ispin = 1, SIZE(mos)
               CALL get_mo_set(mos(ispin), nmo=nmo, nao=nao)
               CALL cp_fm_struct_create(fmstruct, nrow_global=nao, &
                                        ncol_global=nmo, para_env=para_env, &
                                        context=blacs_env)
               CALL fm_pool_create(mpools%ao_mo_fm_pools(ispin)%pool, &
                                   fmstruct)
               CALL cp_fm_struct_release(fmstruct)
            END DO
         END IF
      END IF

      ! momo pools
      should_rebuild = .FALSE.
      DO ispin = 1, nspins
         p_att => mpools%mo_mo_fm_pools(ispin)%pool
         should_rebuild = (should_rebuild .OR. (.NOT. ASSOCIATED(p_att)))
         IF (.NOT. should_rebuild) THEN
            fmstruct => fm_pool_get_el_struct(p_att)
            CALL cp_fm_struct_get(fmstruct, nrow_global=nrg, &
                                  ncol_global=ncg)
            CALL get_mo_set(mos(1), nao=nao, nmo=nmo)
            should_rebuild = nmo /= nrg .OR. nmo /= ncg
         END IF
      END DO
      IF (should_rebuild) THEN
         DO ispin = 1, nspins
            CALL fm_pool_release(mpools%mo_mo_fm_pools(ispin)%pool)
         END DO

         IF (max_nmo == min_nmo) THEN
            CALL cp_fm_struct_create(fmstruct, nrow_global=max_nmo, &
                                     ncol_global=max_nmo, para_env=para_env, &
                                     context=blacs_env)
            CALL fm_pool_create(mpools%mo_mo_fm_pools(1)%pool, &
                                fmstruct)
            CALL cp_fm_struct_release(fmstruct)
            DO ispin = 2, SIZE(mos)
               mpools%mo_mo_fm_pools(ispin)%pool => mpools%mo_mo_fm_pools(1)%pool
               CALL fm_pool_retain(mpools%mo_mo_fm_pools(1)%pool)
            END DO
         ELSE
            DO ispin = 1, SIZE(mos)
               NULLIFY (mpools%mo_mo_fm_pools(ispin)%pool)
               CALL get_mo_set(mos(ispin), nmo=nmo, nao=nao)
               CALL cp_fm_struct_create(fmstruct, nrow_global=nmo, &
                                        ncol_global=nmo, para_env=para_env, &
                                        context=blacs_env)
               CALL fm_pool_create(mpools%mo_mo_fm_pools(ispin)%pool, &
                                   fmstruct)
               CALL cp_fm_struct_release(fmstruct)
            END DO
         END IF
      END IF

      IF (prepare_subset) THEN
         ! aomosub pools
         should_rebuild = .FALSE.
         DO ispin = 1, nspins
            p_att => mpools%ao_mosub_fm_pools(ispin)%pool
            should_rebuild = (should_rebuild .OR. (.NOT. ASSOCIATED(p_att)))
            IF (.NOT. should_rebuild) THEN
               fmstruct => fm_pool_get_el_struct(mpools%ao_mosub_fm_pools(ispin) &
                                                 %pool)
               CALL cp_fm_struct_get(fmstruct, nrow_global=nrg, &
                                     ncol_global=ncg)
               CALL get_mo_set(mos(1), nao=nao)
               should_rebuild = nao /= nrg .OR. nmosub(ispin) /= ncg
            END IF
         END DO
         IF (should_rebuild) THEN
            DO ispin = 1, nspins
               CALL fm_pool_release(mpools%ao_mosub_fm_pools(ispin)%pool)
            END DO

            IF (nspins == 1 .OR. nmosub(1) == nmosub(2)) THEN
               CALL cp_fm_struct_create(fmstruct, nrow_global=nao, &
                                        ncol_global=nmosub(1), para_env=para_env, &
                                        context=blacs_env)
               CALL fm_pool_create(mpools%ao_mosub_fm_pools(1)%pool, fmstruct)
               CALL cp_fm_struct_release(fmstruct)
               DO ispin = 2, SIZE(mos)
                  mpools%ao_mosub_fm_pools(ispin)%pool => mpools%ao_mosub_fm_pools(1)%pool
                  CALL fm_pool_retain(mpools%ao_mosub_fm_pools(1)%pool)
               END DO
            ELSE
               DO ispin = 1, SIZE(mos)
                  CALL get_mo_set(mos(ispin), nao=nao)
                  CALL cp_fm_struct_create(fmstruct, nrow_global=nao, &
                                           ncol_global=nmosub(1), para_env=para_env, &
                                           context=blacs_env)
                  CALL fm_pool_create(mpools%ao_mosub_fm_pools(ispin)%pool, &
                                      fmstruct)
                  CALL cp_fm_struct_release(fmstruct)
               END DO
            END IF
         END IF ! should_rebuild

         ! mosubmosub pools
         should_rebuild = .FALSE.
         DO ispin = 1, nspins
            p_att => mpools%mosub_mosub_fm_pools(ispin)%pool
            should_rebuild = (should_rebuild .OR. (.NOT. ASSOCIATED(p_att)))
            IF (.NOT. should_rebuild) THEN
               fmstruct => fm_pool_get_el_struct(p_att)
               CALL cp_fm_struct_get(fmstruct, nrow_global=nrg, &
                                     ncol_global=ncg)
               should_rebuild = nmosub(ispin) /= nrg .OR. nmosub(ispin) /= ncg
            END IF
         END DO
         IF (should_rebuild) THEN
            DO ispin = 1, nspins
               CALL fm_pool_release(mpools%mosub_mosub_fm_pools(ispin)%pool)
            END DO

            IF (nspins == 1 .OR. nmosub(1) == nmosub(2)) THEN
               CALL cp_fm_struct_create(fmstruct, nrow_global=nmosub(1), &
                                        ncol_global=nmosub(1), para_env=para_env, &
                                        context=blacs_env)
               CALL fm_pool_create(mpools%mosub_mosub_fm_pools(1)%pool, &
                                   fmstruct)
               CALL cp_fm_struct_release(fmstruct)
               DO ispin = 2, SIZE(mos)
                  mpools%mosub_mosub_fm_pools(ispin)%pool => mpools%mosub_mosub_fm_pools(1)%pool
                  CALL fm_pool_retain(mpools%mosub_mosub_fm_pools(1)%pool)
               END DO
            ELSE
               DO ispin = 1, SIZE(mos)
                  NULLIFY (mpools%mosub_mosub_fm_pools(ispin)%pool)
                  CALL cp_fm_struct_create(fmstruct, nrow_global=nmosub(ispin), &
                                           ncol_global=nmosub(ispin), para_env=para_env, &
                                           context=blacs_env)
                  CALL fm_pool_create(mpools%mosub_mosub_fm_pools(ispin)%pool, &
                                      fmstruct)
                  CALL cp_fm_struct_release(fmstruct)
               END DO
            END IF
         END IF ! should_rebuild
      END IF ! prepare_subset

      CALL timestop(handle)
   END SUBROUTINE mpools_rebuild_fm_pools

! **************************************************************************************************

END MODULE qs_matrix_pools
